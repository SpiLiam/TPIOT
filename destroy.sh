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
# 4. Instances EC2
# ════════════════════════════════════════════════════════════
log "4. Terminaison des instances EC2..."
INSTANCES=""
for INST_VAR in INST_GW1 INST_GW2 INST_SNORT INST_INGESTION; do
  INST_ID="${!INST_VAR:-}"
  [ -n "$INST_ID" ] && INSTANCES="$INSTANCES $INST_ID"
done

# Fallback : chercher par tag Project si state vide
if [ -z "$INSTANCES" ]; then
  INSTANCES=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" \
              "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || true)
fi

if [ -n "$INSTANCES" ]; then
  aws ec2 terminate-instances --region "$REGION" \
    --instance-ids $INSTANCES > /dev/null 2>/dev/null || true
  log "Attente terminaison instances..."
  aws ec2 wait instance-terminated --region "$REGION" \
    --instance-ids $INSTANCES 2>/dev/null || true
  log "Instances terminees"
else
  skip "Aucune instance EC2 trouvee"
fi

# ════════════════════════════════════════════════════════════
# 5. Security Groups
# ════════════════════════════════════════════════════════════
log "5. Suppression Security Groups..."
sleep 5

# Chercher par tag si variables pas dans le state
SG_IDS=""
for SG_VAR in SG_GW SG_SNORT SG_INGESTION SG_NLB; do
  SG_ID="${!SG_VAR:-}"
  [ -n "$SG_ID" ] && SG_IDS="$SG_IDS $SG_ID"
done

if [ -z "$SG_IDS" ]; then
  SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'SecurityGroups[].GroupId' \
    --output text 2>/dev/null || true)
fi

for SG_ID in $SG_IDS; do
  safe_delete aws ec2 delete-security-group \
    --region "$REGION" --group-id "$SG_ID"
done

# ════════════════════════════════════════════════════════════
# 6. NAT Gateway + EIP
# ════════════════════════════════════════════════════════════
log "6. Suppression NAT Gateway..."

# Fallback : chercher par tag
if [ -z "${NAT_GW:-}" ] && [ -n "${VPC_ID:-}" ]; then
  NAT_GW=$(none_to_empty "$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)")
fi

if [ -n "${NAT_GW:-}" ]; then
  safe_delete aws ec2 delete-nat-gateway \
    --region "$REGION" --nat-gateway-id "$NAT_GW"
  log "Attente suppression NAT Gateway (2-3 min)..."
  aws ec2 wait nat-gateway-deleted --region "$REGION" \
    --nat-gateway-ids "$NAT_GW" 2>/dev/null || sleep 90
fi

[ -n "${EIP_ALLOC:-}" ] && safe_delete aws ec2 release-address \
  --region "$REGION" --allocation-id "$EIP_ALLOC"

# ════════════════════════════════════════════════════════════
# 7. Route Tables
# ════════════════════════════════════════════════════════════
log "7. Suppression Route Tables..."

RT_IDS=""
for RT_VAR in RT_DMZ RT_PRIVATE; do
  RT_ID="${!RT_VAR:-}"
  [ -n "$RT_ID" ] && RT_IDS="$RT_IDS $RT_ID"
done

# Fallback : chercher par tag
if [ -z "$RT_IDS" ] && [ -n "${VPC_ID:-}" ]; then
  RT_IDS=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Project,Values=$PROJECT" \
    --query 'RouteTables[].RouteTableId' --output text 2>/dev/null || true)
fi

for RT_ID in $RT_IDS; do
  ASSOCS=$(aws ec2 describe-route-tables --region "$REGION" \
    --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
    --output text 2>/dev/null || true)
  for ASSOC in $ASSOCS; do
    safe_delete aws ec2 disassociate-route-table \
      --region "$REGION" --association-id "$ASSOC"
  done
  safe_delete aws ec2 delete-route-table \
    --region "$REGION" --route-table-id "$RT_ID"
done

# ════════════════════════════════════════════════════════════
# 8. NACLs
# ════════════════════════════════════════════════════════════
log "8. Suppression NACLs..."
if [ -n "${VPC_ID:-}" ]; then
  DEFAULT_NACL=$(none_to_empty "$(aws ec2 describe-network-acls --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=true" \
    --query 'NetworkAcls[0].NetworkAclId' --output text 2>/dev/null)")

  NACL_IDS=""
  for NACL_VAR in NACL_DMZ NACL_PRIVATE; do
    NACL_ID="${!NACL_VAR:-}"
    [ -n "$NACL_ID" ] && NACL_IDS="$NACL_IDS $NACL_ID"
  done

  # Fallback : chercher par VPC
  if [ -z "$NACL_IDS" ]; then
    NACL_IDS=$(aws ec2 describe-network-acls --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=false" \
      --query 'NetworkAcls[].NetworkAclId' --output text 2>/dev/null || true)
  fi

  for NACL_ID in $NACL_IDS; do
    if [ -n "$DEFAULT_NACL" ]; then
      ASSOCS=$(aws ec2 describe-network-acls --region "$REGION" \
        --network-acl-ids "$NACL_ID" \
        --query 'NetworkAcls[0].Associations[].NetworkAclAssociationId' \
        --output text 2>/dev/null || true)
      for ASSOC in $ASSOCS; do
        aws ec2 replace-network-acl-association --region "$REGION" \
          --association-id "$ASSOC" --network-acl-id "$DEFAULT_NACL" \
          > /dev/null 2>/dev/null || true
      done
    fi
    safe_delete aws ec2 delete-network-acl \
      --region "$REGION" --network-acl-id "$NACL_ID"
  done
fi

# ════════════════════════════════════════════════════════════
# 9. Subnets
# ════════════════════════════════════════════════════════════
log "9. Suppression Subnets..."

SUBNET_IDS=""
for SN_VAR in SUBNET_DMZ SUBNET_PRIVATE; do
  SN_ID="${!SN_VAR:-}"
  [ -n "$SN_ID" ] && SUBNET_IDS="$SUBNET_IDS $SN_ID"
done

# Fallback : chercher par VPC
if [ -z "$SUBNET_IDS" ] && [ -n "${VPC_ID:-}" ]; then
  SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)
fi

for SN_ID in $SUBNET_IDS; do
  safe_delete aws ec2 delete-subnet \
    --region "$REGION" --subnet-id "$SN_ID"
done

# ════════════════════════════════════════════════════════════
# 10. Internet Gateway
# ════════════════════════════════════════════════════════════
log "10. Suppression Internet Gateway..."

# Fallback : chercher par VPC
if [ -z "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  IGW_ID=$(none_to_empty "$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)")
fi

if [ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  safe_delete aws ec2 detach-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  safe_delete aws ec2 delete-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID"
fi

# ════════════════════════════════════════════════════════════
# 11. VPC
# ════════════════════════════════════════════════════════════
log "11. Suppression VPC..."

# Fallback : chercher par tag
if [ -z "${VPC_ID:-}" ]; then
  VPC_ID=$(none_to_empty "$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)")
fi

[ -n "${VPC_ID:-}" ] && safe_delete aws ec2 delete-vpc \
  --region "$REGION" --vpc-id "$VPC_ID"

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
