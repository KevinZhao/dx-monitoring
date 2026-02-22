#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

require_vars AMI_ID PROBE_SG_ID WORKLOAD_SUBNETS PROBE_INSTANCE_TYPE KEY_PAIR_NAME

parse_subnets WORKLOAD_SUBNETS

USERDATA=$(cat <<'UDEOF'
#!/bin/bash
set -ex
yum install -y python3 python3-pip tcpdump
# Optimize NIC for high packet rate
ethtool -G eth0 rx 4096 tx 4096 2>/dev/null || true
ethtool -C eth0 rx-usecs 0 tx-usecs 0 2>/dev/null || true
echo 16777216 > /proc/sys/net/core/rmem_max
echo 16777216 > /proc/sys/net/core/rmem_default
UDEOF
)

USERDATA_B64=$(echo "$USERDATA" | base64 -w0)

IDX=0
for AZ in "${AZ_LIST[@]}"; do
  VAR_NAME="PROBE_INSTANCE_ID_${IDX}"
  if check_var_exists "$VAR_NAME"; then
    log_info "Probe instance $IDX already exists, skipping"
    IDX=$((IDX + 1))
    continue
  fi

  SUBNET_ID="${SUBNET_MAP[$AZ]}"
  log_info "Launching probe instance in AZ=$AZ subnet=$SUBNET_ID"

  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$PROBE_INSTANCE_TYPE" \
    --key-name "$KEY_PAIR_NAME" \
    --security-group-ids "$PROBE_SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --user-data "$USERDATA_B64" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=dx-probe-${AZ}},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'Instances[0].InstanceId' --output text)

  log_info "Launched probe instance $INSTANCE_ID in $AZ"
  save_var "PROBE_INSTANCE_ID_${IDX}" "$INSTANCE_ID"

  IDX=$((IDX + 1))
done

# Wait for all probe instances to be running
load_env
IDX=0
for AZ in "${AZ_LIST[@]}"; do
  VAR_NAME="PROBE_INSTANCE_ID_${IDX}"
  INSTANCE_ID="${!VAR_NAME}"

  log_info "Waiting for probe instance $INSTANCE_ID to be running..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  log_info "Probe instance $INSTANCE_ID is running"

  PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

  save_var "PROBE_PRIVATE_IP_${IDX}" "$PRIVATE_IP"
  log_info "Probe instance $IDX: id=$INSTANCE_ID ip=$PRIVATE_IP"

  IDX=$((IDX + 1))
done

log_info "All probe instances launched successfully"
