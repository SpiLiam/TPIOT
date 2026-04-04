#!/bin/bash
# ============================================================
# IoT MQTT Architecture - Script de SUPPRESSION
# ATTENTION : Supprime toutes les ressources creees par deploy.sh
# Usage : bash destroy.sh
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
skip()    { echo -e "${BLUE}[SKIP]${NC} $*"; }
del()     { echo -e "${RED}[DELETE]${NC} $*"; }

STATE_FILE="./infra_state.env"
REGION="us-east-1"
PROJECT="iot-mqtt"

[ -f "$STATE_FILE" ] || { echo "State file $STATE_FILE introuvable. Rien a supprimer."; exit 1; }

# Charger le state
source "$STATE_FILE"

echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║     ATTENTION - SUPPRESSION DE TOUTE L'INFRASTRUCTURE   ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  VPC     : ${VPC_ID:-N/A}"
echo -e "  Region  : $REGION"
echo -e "  Compte  : ${ACCOUNT:-N/A}"
echo ""
read -r -p "$(echo -e "${RED}Confirmer la suppression ? Tapez 'DESTROY' pour confirmer :${NC} ")" CONFIRM
[[ "$CONFIRM" == "DESTROY" ]] || { log "Annule."; exit 0; }

safe_delete() {
  # Executer une commande sans planter si elle echoue
  "$@" 2>/dev/null && del "$*" || skip "Deja supprime ou inexistant : $1"
}

# ─── 1. Traffic Mirroring ────────────────────────────────────
log "Suppression Traffic Mirroring..."
[ -n "${SESSION_GW1:-}" ] && safe_delete aws ec2 delete-traffic-mirror-session \
  --region "$REGION" --traffic-mirror-session-id "$SESSION_GW1"
[ -n "${SESSION_GW2:-}" ] && safe_delete aws ec2 delete-traffic-mirror-session \
  --region "$REGION" --traffic-mirror-session-id "$SESSION_GW2"
[ -n "${MIRROR_TARGET:-}" ] && safe_delete aws ec2 delete-traffic-mirror-target \
  --region "$REGION" --traffic-mirror-target-id "$MIRROR_TARGET"
[ -n "${MIRROR_FILTER:-}" ] && safe_delete aws ec2 delete-traffic-mirror-filter \
  --region "$REGION" --traffic-mirror-filter-id "$MIRROR_FILTER"

# ─── 2. Load Balancer ────────────────────────────────────────
log "Suppression NLB (listeners + load balancer + target groups)..."

# Listeners (8883 + 1883)
[ -n "${LISTENER_ARN:-}" ]  && safe_delete aws elbv2 delete-listener \
  --region "$REGION" --listener-arn "$LISTENER_ARN"
[ -n "${LISTENER_1883:-}" ] && safe_delete aws elbv2 delete-listener \
  --region "$REGION" --listener-arn "$LISTENER_1883"

[ -n "${NLB_ARN:-}" ] && safe_delete aws elbv2 delete-load-balancer \
  --region "$REGION" --load-balancer-arn "$NLB_ARN"

if [ -n "${NLB_ARN:-}" ]; then
  log "Attente suppression NLB..."
  aws elbv2 wait load-balancers-deleted --region "$REGION" \
    --load-balancer-arns "$NLB_ARN" 2>/dev/null || true
fi

# Target Groups (8883 + 1883)
[ -n "${TG_ARN:-}"   ] && safe_delete aws elbv2 delete-target-group \
  --region "$REGION" --target-group-arn "$TG_ARN"
[ -n "${TG_1883:-}"  ] && safe_delete aws elbv2 delete-target-group \
  --region "$REGION" --target-group-arn "$TG_1883"

# ─── 3. Simulateur (arret service avant terminaison EC2) ─────
log "Arret du simulateur temperature..."
if [ -n "${INST_INGESTION:-}" ]; then
  SSM_READY=$(aws ssm describe-instance-information \
    --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INST_INGESTION" \
    --query 'InstanceInformationList[0].InstanceId' \
    --output text 2>/dev/null || true)
  if [[ "$SSM_READY" == "$INST_INGESTION" ]]; then
    aws ssm send-command \
      --region "$REGION" \
      --instance-ids "$INST_INGESTION" \
      --document-name "AWS-RunShellScript" \
      --parameters 'commands=["systemctl stop iot-simulator 2>/dev/null || true","systemctl disable iot-simulator 2>/dev/null || true"]' \
      > /dev/null 2>/dev/null || true
    del "Service iot-simulator arrete sur $INST_INGESTION"
  else
    skip "SSM non disponible sur ingestion, service non arrete proprement"
  fi
fi

# ─── 4. EC2 Instances ────────────────────────────────────────
log "Terminaison des instances EC2..."
INSTANCES=""
for INST_VAR in INST_GW1 INST_GW2 INST_SNORT INST_INGESTION; do
  INST_ID="${!INST_VAR:-}"
  [ -n "$INST_ID" ] && INSTANCES="$INSTANCES $INST_ID"
done

if [ -n "$INSTANCES" ]; then
  aws ec2 terminate-instances --region "$REGION" \
    --instance-ids $INSTANCES > /dev/null 2>/dev/null || true
  log "Attente terminaison instances..."
  aws ec2 wait instance-terminated --region "$REGION" \
    --instance-ids $INSTANCES 2>/dev/null || true
  log "Instances terminees"
fi

# ─── 4. Security Groups ──────────────────────────────────────
log "Suppression Security Groups..."
sleep 5
for SG_VAR in SG_MQTT_GW SG_SNORT SG_INGESTION; do
  SG_ID="${!SG_VAR:-}"
  [ -n "$SG_ID" ] && safe_delete aws ec2 delete-security-group \
    --region "$REGION" --group-id "$SG_ID"
done

# ─── 5. NAT Gateway + EIP ────────────────────────────────────
log "Suppression NAT Gateway..."
[ -n "${NAT_GW:-}" ] && {
  safe_delete aws ec2 delete-nat-gateway --region "$REGION" --nat-gateway-id "$NAT_GW"
  log "Attente suppression NAT Gateway (2-3 min)..."
  aws ec2 wait nat-gateway-deleted --region "$REGION" \
    --nat-gateway-ids "$NAT_GW" 2>/dev/null || sleep 90
}
[ -n "${EIP_ALLOC:-}" ] && safe_delete aws ec2 release-address \
  --region "$REGION" --allocation-id "$EIP_ALLOC"

# ─── 6. Route Tables ─────────────────────────────────────────
log "Suppression Route Tables..."
for RT_VAR in RT_DMZ RT_PRIVATE; do
  RT_ID="${!RT_VAR:-}"
  if [ -n "$RT_ID" ]; then
    # Dissocier d'abord
    ASSOCS=$(aws ec2 describe-route-tables --region "$REGION" \
      --route-table-ids "$RT_ID" \
      --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
      --output text 2>/dev/null || true)
    for ASSOC in $ASSOCS; do
      safe_delete aws ec2 disassociate-route-table --region "$REGION" \
        --association-id "$ASSOC"
    done
    safe_delete aws ec2 delete-route-table --region "$REGION" --route-table-id "$RT_ID"
  fi
done

# ─── 7. NACLs ────────────────────────────────────────────────
log "Suppression NACLs..."
# Recuperer NACL par defaut du VPC pour reassocier avant suppression
if [ -n "${VPC_ID:-}" ]; then
  DEFAULT_NACL=$(aws ec2 describe-network-acls --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=true" \
    --query 'NetworkAcls[0].NetworkAclId' --output text 2>/dev/null || echo "")

  for NACL_VAR in NACL_DMZ NACL_PRIVATE; do
    NACL_ID="${!NACL_VAR:-}"
    if [ -n "$NACL_ID" ] && [ -n "$DEFAULT_NACL" ]; then
      # Recuperer les associations de ce NACL
      ASSOCS=$(aws ec2 describe-network-acls --region "$REGION" \
        --network-acl-ids "$NACL_ID" \
        --query 'NetworkAcls[0].Associations[].NetworkAclAssociationId' \
        --output text 2>/dev/null || true)
      for ASSOC in $ASSOCS; do
        aws ec2 replace-network-acl-association --region "$REGION" \
          --association-id "$ASSOC" --network-acl-id "$DEFAULT_NACL" > /dev/null 2>/dev/null || true
      done
      safe_delete aws ec2 delete-network-acl --region "$REGION" --network-acl-id "$NACL_ID"
    fi
  done
fi

# ─── 8. Subnets ──────────────────────────────────────────────
log "Suppression Subnets..."
[ -n "${SUBNET_DMZ:-}" ]     && safe_delete aws ec2 delete-subnet \
  --region "$REGION" --subnet-id "$SUBNET_DMZ"
[ -n "${SUBNET_PRIVATE:-}" ] && safe_delete aws ec2 delete-subnet \
  --region "$REGION" --subnet-id "$SUBNET_PRIVATE"

# ─── 9. Internet Gateway ─────────────────────────────────────
log "Suppression Internet Gateway..."
[ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ] && {
  safe_delete aws ec2 detach-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  safe_delete aws ec2 delete-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID"
}

# ─── 10. VPC ─────────────────────────────────────────────────
log "Suppression VPC..."
[ -n "${VPC_ID:-}" ] && safe_delete aws ec2 delete-vpc \
  --region "$REGION" --vpc-id "$VPC_ID"

# ─── 11. CloudWatch ──────────────────────────────────────────
log "Suppression CloudWatch Log Groups et Alarmes..."
for LG in \
  "/iot-mqtt/mqtt-gateway" "/iot-mqtt/snort-alerts" \
  "/iot-mqtt/ingestion" "/iot-mqtt/ingestion-broker" \
  "/iot-mqtt/system" "/iot-mqtt/bootstrap"; do
  safe_delete aws logs delete-log-group --region "$REGION" --log-group-name "$LG"
done

# Supprimer les alarmes
aws cloudwatch describe-alarms --region "$REGION" \
  --alarm-name-prefix "$PROJECT-" \
  --query 'MetricAlarms[].AlarmName' \
  --output text 2>/dev/null | tr '\t' '\n' | while read -r alarm; do
  [ -n "$alarm" ] && safe_delete aws cloudwatch delete-alarms \
    --region "$REGION" --alarm-names "$alarm"
done

# ─── 12. SNS ─────────────────────────────────────────────────
[ -n "${SNS_ARN:-}" ] && safe_delete aws sns delete-topic \
  --region "$REGION" --topic-arn "$SNS_ARN"

# ─── 13. IAM ─────────────────────────────────────────────────
log "Suppression IAM Role..."
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

# ─── Archiver le state ───────────────────────────────────────
mv "$STATE_FILE" "${STATE_FILE}.destroyed_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         SUPPRESSION TERMINEE AVEC SUCCES                ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
log "Toutes les ressources IoT MQTT ont ete supprimees."
