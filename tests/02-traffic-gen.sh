#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/common.sh"
load_config
load_env

TEST_CONF="$SCRIPT_DIR/test-env.conf"
TEST_ENV_FILE="$SCRIPT_DIR/test-env-vars.sh"

source "$TEST_CONF"

# --- test variable persistence ---

test_save_var() {
    local name="$1"
    local value="$2"

    if [[ ! -f "$TEST_ENV_FILE" ]]; then
        echo "# dx-monitoring test environment variables" > "$TEST_ENV_FILE"
        echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$TEST_ENV_FILE"
        echo "" >> "$TEST_ENV_FILE"
    fi

    if grep -q "^${name}=" "$TEST_ENV_FILE" 2>/dev/null; then
        sed -i "s|^${name}=.*|${name}=\"${value}\"|" "$TEST_ENV_FILE"
    else
        echo "${name}=\"${value}\"" >> "$TEST_ENV_FILE"
    fi
    log_info "Saved $name to $TEST_ENV_FILE"
}

test_load_env() {
    if [[ -f "$TEST_ENV_FILE" ]]; then
        source "$TEST_ENV_FILE"
        log_info "Test environment loaded from $TEST_ENV_FILE"
    fi
}

test_check_var_exists() {
    local var_name="$1"
    if [[ ! -f "$TEST_ENV_FILE" ]]; then
        return 1
    fi
    grep -q "^${var_name}=" "$TEST_ENV_FILE" 2>/dev/null
}

test_load_env

require_vars AWS_REGION AMI_ID KEY_PAIR_NAME PROJECT_TAG ADMIN_CIDR
require_vars ONPREM_VPC_ID ONPREM_VPC_CIDR ONPREM_SUBNET_ID

log_info "=== Launching Traffic Generator Instances ==="

# Traffic generator security group
if test_check_var_exists TRAFFIC_GEN_SG_ID; then
    log_info "Traffic gen SG already exists: $TRAFFIC_GEN_SG_ID"
else
    TRAFFIC_GEN_SG_ID=$(aws ec2 create-security-group \
        --group-name "dx-test-traffic-gen-sg" \
        --description "DX Test - Traffic generator instances" \
        --vpc-id "$ONPREM_VPC_ID" \
        --region "$AWS_REGION" \
        --query 'GroupId' --output text)

    aws ec2 create-tags --resources "$TRAFFIC_GEN_SG_ID" \
        --tags "Key=Name,Value=dx-test-traffic-gen-sg" \
              "Key=Project,Value=${PROJECT_TAG}" \
              "Key=Role,Value=test-gen" \
        --region "$AWS_REGION"

    # SSH from admin
    aws ec2 authorize-security-group-ingress \
        --group-id "$TRAFFIC_GEN_SG_ID" \
        --protocol tcp --port 22 \
        --cidr "$ADMIN_CIDR" \
        --region "$AWS_REGION" 2>/dev/null || true

    # All traffic from on-prem VPC
    aws ec2 authorize-security-group-ingress \
        --group-id "$TRAFFIC_GEN_SG_ID" \
        --protocol all \
        --cidr "$ONPREM_VPC_CIDR" \
        --region "$AWS_REGION" 2>/dev/null || true

    test_save_var TRAFFIC_GEN_SG_ID "$TRAFFIC_GEN_SG_ID"
    log_info "Created traffic gen SG: $TRAFFIC_GEN_SG_ID"
fi

# UserData for traffic generators
GEN_USERDATA=$(cat <<'UDEOF'
#!/bin/bash
set -ex
yum install -y iperf3 curl wget
UDEOF
)
GEN_USERDATA_B64=$(echo "$GEN_USERDATA" | base64 -w0)

# Launch traffic generators
for i in $(seq 0 $((TRAFFIC_GEN_COUNT - 1))); do
    VAR_ID="TRAFFIC_GEN_ID_${i}"
    VAR_IP="TRAFFIC_GEN_IP_${i}"

    if test_check_var_exists "$VAR_ID"; then
        log_info "Traffic gen $i already exists: $(eval echo \$${VAR_ID})"
        continue
    fi

    INSTANCE_NAME="dx-traffic-gen-${i}"

    log_info "Launching traffic gen $i in on-prem private subnet $ONPREM_SUBNET_ID"

    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$TRAFFIC_GEN_INSTANCE_TYPE" \
        --key-name "$KEY_PAIR_NAME" \
        --security-group-ids "$TRAFFIC_GEN_SG_ID" \
        --subnet-id "$ONPREM_SUBNET_ID" \
        --user-data "$GEN_USERDATA_B64" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-gen}]" \
        --region "$AWS_REGION" \
        --query 'Instances[0].InstanceId' --output text)

    test_save_var "$VAR_ID" "$INSTANCE_ID"
    log_info "Launched traffic gen $i: $INSTANCE_ID"
done

# Wait for all traffic generators to be running and collect IPs
log_info "Waiting for traffic generators to be running..."
for i in $(seq 0 $((TRAFFIC_GEN_COUNT - 1))); do
    VAR_ID="TRAFFIC_GEN_ID_${i}"
    VAR_IP="TRAFFIC_GEN_IP_${i}"

    test_load_env
    INSTANCE_ID="${!VAR_ID}"

    log_info "Waiting for traffic gen $i ($INSTANCE_ID)..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

    PRIVATE_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

    test_save_var "$VAR_IP" "$PRIVATE_IP"
    log_info "Traffic gen $i: id=$INSTANCE_ID ip=$PRIVATE_IP"
done

# Summary
test_load_env
echo ""
log_info "===== Traffic Generators Summary ====="
for i in $(seq 0 $((TRAFFIC_GEN_COUNT - 1))); do
    VAR_ID="TRAFFIC_GEN_ID_${i}"
    VAR_IP="TRAFFIC_GEN_IP_${i}"
    log_info "  Gen $i: ${!VAR_ID} (${!VAR_IP})"
done
log_info "======================================="
echo ""
log_info "Traffic generators ready."
log_info "Traffic flows: traffic-gen -> CGW -> VPN -> VGW -> GWLB -> Appliance -> Mirror -> Probe"
