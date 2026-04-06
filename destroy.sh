#!/bin/bash
# ============================================================
# IoT MQTT Architecture - Script de SUPPRESSION
# ATTENTION : Supprime toutes les ressources creees par deploy.sh
# Usage : bash destroy.sh
#
# Robuste : cherche les ressources par nom/tag si le state
# file est incomplet (deploy interrompu, etc.)
# ============================================================

set +e  # Ne pas stopper sur erreur — on nettoie au mieux

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
skip()    { echo -e "${BLUE}[SKIP]${NC} $*"; }
del()     { echo -e "${RED}[DELETE]${NC} $*"; }

STATE_FILE="./infra_state.env"
REGION="us-east-1"
PROJECT="iot-mqtt"

# ── Charger le state si dispo ─────────────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
  source "$STATE_FILE"
  log "State file charge : $STATE_FILE"
else
  warn "State file introuvable — recherche des ressources par nom/tag dans AWS..."
fi

echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║     ATTENTION - SUPPRESSION DE TOUTE L'INFRASTRUCTURE   ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  VPC     : ${VPC_ID:-N/A (sera cherche par tag)}"
echo -e "  Region  : $REGION"
echo -e "  Compte  : ${ACCOUNT:-N/A}"
echo ""
read -r -p "$(echo -e "${RED}Confirmer la suppression ? Tapez 'DESTROY' pour confirmer :${NC} ")" CONFIRM
[[ "$CONFIRM" == "DESTROY" ]] || { log "Annule."; exit 0; }

safe_delete() {
  "$@" 2>/dev/null && del "$(echo "$*" | cut -d' ' -f1-5)..." \
    || skip "Deja supprime ou inexistant"
}

none_to_empty() {
  # Convertit "None" ou "null" en chaine vide
  local val="$1"
  [[ "$val" == "None" || "$val" == "null" || -z "$val" ]] && echo "" || echo "$val"
}

# ════════════════════════════════════════════════════════════
# 1. Traffic Mirroring
# ════════════════════════════════════════════════════════════
log "1. Suppression Traffic Mirroring..."

# Chercher les sessions par filtre si pas dans le state
if [ -z "${SESSION_GW1:-}" ] && [ -z "${SESSION_GW2:-}" ]; then
  SESSIONS=$(aws ec2 describe-traffic-mirror-sessions --region "$REGION" \
    --query 'TrafficMirrorSessions[].TrafficMirrorSessionId' \
    --output text 2>/dev/null || true)
  for S in $SESSIONS; do
    safe_delete aws ec2 delete-traffic-mirror-session \
      --region "$REGION" --traffic-mirror-session-id "$S"
  done
else
  [ -n "${SESSION_GW1:-}" ] && safe_delete aws ec2 delete-traffic-mirror-session \
    --region "$REGION" --traffic-mirror-session-id "$SESSION_GW1"
  [ -n "${SESSION_GW2:-}" ] && safe_delete aws ec2 delete-traffic-mirror-session \
    --region "$REGION" --traffic-mirror-session-id "$SESSION_GW2"
fi

[ -n "${MIRROR_FILTER:-}" ] && safe_delete aws ec2 delete-traffic-mirror-filter \
  --region "$REGION" --traffic-mirror-filter-id "$MIRROR_FILTER"
[ -n "${MIRROR_TARGET:-}" ] && safe_delete aws ec2 delete-traffic-mirror-target \
  --region "$REGION" --traffic-mirror-target-id "$MIRROR_TARGET"

# ════════════════════════════════════════════════════════════
# 2. Network Load Balancer
# ════════════════════════════════════════════════════════════
log "2. Suppression NLB..."

# Fallback : chercher par nom si ARN pas dans le state
if [ -z "${NLB_ARN:-}" ]; then
  NLB_ARN=$(none_to_empty "$(aws elbv2 describe-load-balancers \
    --region "$REGION" --names "${PROJECT}-nlb" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)")
fi

if [ -n "${NLB_ARN:-}" ]; then
  # Supprimer TOUS les listeners (pas seulement les ARNs trackes)
  LISTENER_ARNS=$(aws elbv2 describe-listeners \
    --region "$REGION" --load-balancer-arn "$NLB_ARN" \
    --query 'Listeners[].ListenerArn' --output text 2>/dev/null || true)
  for L_ARN in $LISTENER_ARNS; do
    safe_delete aws elbv2 delete-listener \
      --region "$REGION" --listener-arn "$L_ARN"
  done
  safe_delete aws elbv2 delete-load-balancer \
    --region "$REGION" --load-balancer-arn "$NLB_ARN"
  log "Attente suppression NLB..."
  aws elbv2 wait load-balancers-deleted \
    --region "$REGION" --load-balancer-arns "$NLB_ARN" 2>/dev/null || true
else
  skip "Aucun NLB trouve"
fi

# Supprimer TOUS les target groups du projet (par prefixe de nom)
TG_ARNS=$(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?starts_with(TargetGroupName, '${PROJECT}')].TargetGroupArn" \
  --output text 2>/dev/null || true)
for TG in $TG_ARNS; do
  safe_delete aws elbv2 delete-target-group \
    --region "$REGION" --target-group-arn "$TG"
done

# ════════════════════════════════════════════════════════════
# 3. Simulateur (arret propre avant terminaison EC2)
# ════════════════════════════════════════════════════════════
log "3. Arret du simulateur temperature..."
if [ -n "${INST_INGESTION:-}" ]; then
  SSM_UP=$(aws ssm describe-instance-information \
    --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INST_INGESTION" \
    --query 'InstanceInformationList[0].InstanceId' \
    --output text 2>/dev/null || true)
  if [[ "$SSM_UP" == "$INST_INGESTION" ]]; then
    aws ssm send-command \
      --region "$REGION" --instance-ids "$INST_INGESTION" \
      --document-name "AWS-RunShellScript" \
      --parameters 'commands=["systemctl stop iot-simulator 2>/dev/null || true"]' \
      > /dev/null 2>/dev/null || true
    del "Service iot-simulator arrete"
  else
    skip "SSM non disponible sur ingestion"
  fi
fi

# ════════════════════════════════════════════════════════════
# Fonction : purge complète d'un VPC (toutes ses dépendances)
# Appelée sur le VPC du state + tous les VPCs orphelins du projet
# ════════════════════════════════════════════════════════════
purge_vpc() {
  local VPC="$1"
  [ -z "$VPC" ] && return
  log "Purge VPC $VPC..."

  # ── EC2 Instances ────────────────────────────────────────
  INSTS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" \
              "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || true)
  if [ -n "$INSTS" ]; then
    aws ec2 terminate-instances --region "$REGION" \
      --instance-ids $INSTS > /dev/null 2>/dev/null || true
    log "  Attente terminaison instances de $VPC..."
    aws ec2 wait instance-terminated --region "$REGION" \
      --instance-ids $INSTS 2>/dev/null || true
  fi

  # ── NAT Gateways ─────────────────────────────────────────
  NAT_IDS=$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=available,pending" \
    --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)
  for NAT in $NAT_IDS; do
    aws ec2 delete-nat-gateway --region "$REGION" \
      --nat-gateway-id "$NAT" > /dev/null 2>/dev/null || true
    del "  NAT GW $NAT"
  done
  # Attendre la suppression de tous les NAT GW avant de libérer les EIPs
  for NAT in $NAT_IDS; do
    aws ec2 wait nat-gateway-deleted --region "$REGION" \
      --nat-gateway-ids "$NAT" 2>/dev/null || sleep 60
  done

  # ── EIPs associées au VPC (via NAT GW) ───────────────────
  EIP_IDS=$(aws ec2 describe-addresses --region "$REGION" \
    --query "Addresses[?Domain=='vpc' && AssociationId==null].AllocationId" \
    --output text 2>/dev/null || true)
  for EIP in $EIP_IDS; do
    aws ec2 release-address --region "$REGION" \
      --allocation-id "$EIP" 2>/dev/null || true
  done

  # ── Internet Gateways ─────────────────────────────────────
  for IGW in $(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC" \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text 2>/dev/null || true); do
    aws ec2 detach-internet-gateway --region "$REGION" \
      --internet-gateway-id "$IGW" --vpc-id "$VPC" 2>/dev/null || true
    aws ec2 delete-internet-gateway --region "$REGION" \
      --internet-gateway-id "$IGW" 2>/dev/null && del "  IGW $IGW" || true
  done

  # ── NACLs (non-default) ───────────────────────────────────
  DEFAULT_NACL=$(aws ec2 describe-network-acls --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" "Name=default,Values=true" \
    --query 'NetworkAcls[0].NetworkAclId' --output text 2>/dev/null || true)
  for NACL in $(aws ec2 describe-network-acls --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" "Name=default,Values=false" \
    --query 'NetworkAcls[].NetworkAclId' --output text 2>/dev/null || true); do
    [ -n "$DEFAULT_NACL" ] && for ASSOC in $(aws ec2 describe-network-acls \
      --region "$REGION" --network-acl-ids "$NACL" \
      --query 'NetworkAcls[0].Associations[].NetworkAclAssociationId' \
      --output text 2>/dev/null || true); do
      aws ec2 replace-network-acl-association --region "$REGION" \
        --association-id "$ASSOC" --network-acl-id "$DEFAULT_NACL" \
        > /dev/null 2>/dev/null || true
    done
    aws ec2 delete-network-acl --region "$REGION" \
      --network-acl-id "$NACL" 2>/dev/null || true
  done

  # ── Route Tables (non-main) ───────────────────────────────
  for RT in $(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
    --output text 2>/dev/null || true); do
    for ASSOC in $(aws ec2 describe-route-tables --region "$REGION" \
      --route-table-ids "$RT" \
      --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
      --output text 2>/dev/null || true); do
      aws ec2 disassociate-route-table --region "$REGION" \
        --association-id "$ASSOC" 2>/dev/null || true
    done
    aws ec2 delete-route-table --region "$REGION" \
      --route-table-id "$RT" 2>/dev/null || true
  done

  # ── Subnets ───────────────────────────────────────────────
  for SN in $(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || true); do
    aws ec2 delete-subnet --region "$REGION" \
      --subnet-id "$SN" 2>/dev/null || true
  done

  # ── Security Groups (non-default) ────────────────────────
  sleep 5
  for SG in $(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text 2>/dev/null || true); do
    aws ec2 delete-security-group --region "$REGION" \
      --group-id "$SG" 2>/dev/null || true
  done

  # ── VPC ───────────────────────────────────────────────────
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC" 2>/dev/null \
    && del "  VPC $VPC supprime" \
    || warn "  VPC $VPC : suppression echouee (ressources encore presentes ?)"
}

# ════════════════════════════════════════════════════════════
# 4. EC2 + NAT + SGs + Subnets + IGW + VPC
#    (via purge_vpc sur le VPC du state ET tous les orphelins)
# ════════════════════════════════════════════════════════════
log "4. Suppression EC2, NAT, SGs, Subnets, IGW, VPCs..."

# Collecter tous les VPCs du projet (state + orphelins par tag/nom)
ALL_VPCS=""
[ -n "${VPC_ID:-}" ] && ALL_VPCS="$VPC_ID"

ORPHAN_VPCS=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)

# Aussi chercher par nom si pas de tag (déploiements anciens)
NAMED_VPCS=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)

for V in $ORPHAN_VPCS $NAMED_VPCS; do
  [[ "$ALL_VPCS" != *"$V"* ]] && ALL_VPCS="$ALL_VPCS $V"
done

if [ -n "$ALL_VPCS" ]; then
  for V in $ALL_VPCS; do
    purge_vpc "$V"
  done
else
  skip "Aucun VPC du projet trouve"
fi

# EIP restante du state (si pas libérée dans purge_vpc)
[ -n "${EIP_ALLOC:-}" ] && aws ec2 release-address \
  --region "$REGION" --allocation-id "$EIP_ALLOC" 2>/dev/null || true

# ════════════════════════════════════════════════════════════
# 12. CloudWatch + SNS
# ════════════════════════════════════════════════════════════
log "12. Suppression CloudWatch Log Groups et Alarmes..."
for LG in \
  "/iot-mqtt/mqtt-gateway" "/iot-mqtt/snort-alerts" \
  "/iot-mqtt/ingestion" "/iot-mqtt/ingestion-broker" \
  "/iot-mqtt/system" "/iot-mqtt/bootstrap"; do
  safe_delete aws logs delete-log-group \
    --region "$REGION" --log-group-name "$LG"
done

aws cloudwatch describe-alarms --region "$REGION" \
  --alarm-name-prefix "${PROJECT}-" \
  --query 'MetricAlarms[].AlarmName' \
  --output text 2>/dev/null | tr '\t' '\n' | while read -r alarm; do
  [ -n "$alarm" ] && safe_delete aws cloudwatch delete-alarms \
    --region "$REGION" --alarm-names "$alarm"
done

[ -n "${SNS_ARN:-}" ] && safe_delete aws sns delete-topic \
  --region "$REGION" --topic-arn "$SNS_ARN"

# ════════════════════════════════════════════════════════════
# 13. IAM Role
# ════════════════════════════════════════════════════════════
log "13. Suppression IAM Role..."
ROLE_NAME="${PROJECT}-ec2-role"
PROFILE_NAME="${PROJECT}-ec2-profile"

aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME" 2>/dev/null || true

safe_delete aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"

for POLICY in \
  "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
  "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"; do
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY" 2>/dev/null || true
done
safe_delete aws iam delete-role --role-name "$ROLE_NAME"

# ════════════════════════════════════════════════════════════
# Archiver le state
# ════════════════════════════════════════════════════════════
if [ -f "$STATE_FILE" ]; then
  mv "$STATE_FILE" "${STATE_FILE}.destroyed_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         SUPPRESSION TERMINEE AVEC SUCCES                ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
log "Toutes les ressources IoT MQTT ont ete supprimees."
