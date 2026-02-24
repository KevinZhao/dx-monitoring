#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

require_vars AMI_ID PROBE_SG_ID WORKLOAD_SUBNETS PROBE_INSTANCE_TYPE KEY_PAIR_NAME

PROBE_COUNT=${PROBE_COUNT:-1}

# --- IAM Instance Profile for Probe ---
PROBE_ROLE_NAME="dx-probe-role-${PROJECT_TAG}"

if check_var_exists PROBE_INSTANCE_PROFILE; then
    log_info "Probe IAM profile already exists: $PROBE_INSTANCE_PROFILE"
else
    log_info "Creating IAM role for Probe instances..."

    TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

    aws iam create-role \
        --role-name "$PROBE_ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --tags "Key=Project,Value=${PROJECT_TAG}" 2>/dev/null \
        || log_info "IAM role already exists"

    PROBE_POLICY='{
        "Version":"2012-10-17",
        "Statement":[
            {"Effect":"Allow","Action":["ec2:DescribeInstances","ec2:DescribeNetworkInterfaces"],"Resource":"*"},
            {"Effect":"Allow","Action":"sns:Publish","Resource":"'"${SNS_TOPIC_ARN:-*}"'"}
        ]
    }'
    aws iam put-role-policy \
        --role-name "$PROBE_ROLE_NAME" \
        --policy-name "dx-probe-policy" \
        --policy-document "$PROBE_POLICY"

    aws iam create-instance-profile \
        --instance-profile-name "$PROBE_ROLE_NAME" 2>/dev/null || true
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$PROBE_ROLE_NAME" \
        --role-name "$PROBE_ROLE_NAME" 2>/dev/null || true

    # IAM propagation delay
    log_info "Waiting for IAM profile propagation..."
    sleep 10

    save_var PROBE_INSTANCE_PROFILE "$PROBE_ROLE_NAME"
    save_var PROBE_IAM_ROLE_NAME "$PROBE_ROLE_NAME"
    log_info "Created IAM profile: $PROBE_ROLE_NAME"
fi

load_env

parse_subnets WORKLOAD_SUBNETS

USERDATA=$(cat <<'UDEOF'
#!/bin/bash
set -ex
yum install -y python3 python3-pip tcpdump gcc

# --- NIC ring buffer & interrupt coalescing ---
ethtool -G eth0 rx 4096 tx 4096 2>/dev/null || true
ethtool -C eth0 rx-usecs 0 tx-usecs 0 2>/dev/null || true

# --- Socket buffer: 256MB max, 128MB default ---
echo 268435456 > /proc/sys/net/core/rmem_max
echo 134217728 > /proc/sys/net/core/rmem_default

# --- Kernel RX queue depth ---
echo 300000 > /proc/sys/net/core/netdev_max_backlog

# --- GRO aggregation ---
ethtool -K eth0 gro on 2>/dev/null || true

# --- RPS multi-core distribution ---
CPUS=$(nproc)
RPS_MASK=$(printf '%x' $(( (1 << CPUS) - 1 )))
for f in /sys/class/net/eth0/queues/rx-*/rps_cpus; do
    echo "$RPS_MASK" > "$f" 2>/dev/null || true
done
echo 65536 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

# --- Compile C parser if source exists ---
if [[ -f /home/ec2-user/probe/fast_parse.c ]]; then
    gcc -O2 -shared -fPIC -o /home/ec2-user/probe/fast_parse.so /home/ec2-user/probe/fast_parse.c
fi
UDEOF
)

USERDATA_B64=$(echo "$USERDATA" | base64 -w0)

IDX=0
for AZ in "${AZ_LIST[@]}"; do
  SUBNET_ID="${SUBNET_MAP[$AZ]}"

  for N in $(seq 0 $((PROBE_COUNT - 1))); do
    VAR_NAME="PROBE_INSTANCE_ID_${IDX}"
    if check_var_exists "$VAR_NAME"; then
      log_info "Probe instance $IDX already exists, skipping"
      IDX=$((IDX + 1))
      continue
    fi

    log_info "Launching probe instance ${N} in AZ=$AZ subnet=$SUBNET_ID"

    INSTANCE_ID=$(aws ec2 run-instances \
      --image-id "$AMI_ID" \
      --instance-type "$PROBE_INSTANCE_TYPE" \
      --key-name "$KEY_PAIR_NAME" \
      --security-group-ids "$PROBE_SG_ID" \
      --subnet-id "$SUBNET_ID" \
      --user-data "$USERDATA_B64" \
      --iam-instance-profile "Name=${PROBE_INSTANCE_PROFILE}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=dx-probe-${AZ}-${N}},{Key=Project,Value=${PROJECT_TAG}}]" \
      --query 'Instances[0].InstanceId' --output text)

    log_info "Launched probe instance $INSTANCE_ID in $AZ (index=$N)"
    save_var "PROBE_INSTANCE_ID_${IDX}" "$INSTANCE_ID"

    IDX=$((IDX + 1))
  done
done

# Wait for all probe instances to be running
load_env
IDX=0
for AZ in "${AZ_LIST[@]}"; do
  for N in $(seq 0 $((PROBE_COUNT - 1))); do
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
done

log_info "All probe instances launched successfully"
