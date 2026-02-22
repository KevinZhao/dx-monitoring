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

require_vars AWS_REGION VPC_ID VPC_CIDR AMI_ID KEY_PAIR_NAME PROJECT_TAG ADMIN_CIDR
require_vars ONPREM_VPC_CIDR

# Need at least one business subnet from main config
# Parse BUSINESS_SUBNET_CIDRS to identify which subnets to use
# We'll find subnets in the monitoring VPC tagged for business use, or use the first available
log_info "=== Launching Business Host Instances ==="

# Resolve a suitable subnet in the monitoring VPC
# Use the first probe/appliance subnet as business subnet (they're in the same VPC)
# The caller should have BUSINESS_SUBNET_CIDRS in the main config
BIZ_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --region "$AWS_REGION" \
    --query 'Subnets[].SubnetId' --output text)

# Pick subnets round-robin from available ones
BIZ_SUBNET_ARR=($BIZ_SUBNETS)
if [[ ${#BIZ_SUBNET_ARR[@]} -eq 0 ]]; then
    log_error "No subnets found in VPC $VPC_ID"
    exit 1
fi

# Business host security group
if test_check_var_exists BIZ_HOST_SG_ID; then
    log_info "Business host SG already exists: $BIZ_HOST_SG_ID"
else
    BIZ_HOST_SG_ID=$(aws ec2 create-security-group \
        --group-name "dx-test-biz-host-sg" \
        --description "DX Test - Business host instances" \
        --vpc-id "$VPC_ID" \
        --region "$AWS_REGION" \
        --query 'GroupId' --output text)

    aws ec2 create-tags --resources "$BIZ_HOST_SG_ID" \
        --tags "Key=Name,Value=dx-test-biz-host-sg" \
              "Key=Project,Value=${PROJECT_TAG}" \
              "Key=Role,Value=test-biz" \
        --region "$AWS_REGION"

    # All traffic from monitoring VPC
    aws ec2 authorize-security-group-ingress \
        --group-id "$BIZ_HOST_SG_ID" \
        --protocol all \
        --cidr "$VPC_CIDR" \
        --region "$AWS_REGION" 2>/dev/null || true

    # All traffic from on-prem VPC (via VPN)
    aws ec2 authorize-security-group-ingress \
        --group-id "$BIZ_HOST_SG_ID" \
        --protocol all \
        --cidr "$ONPREM_VPC_CIDR" \
        --region "$AWS_REGION" 2>/dev/null || true

    # SSH from admin
    aws ec2 authorize-security-group-ingress \
        --group-id "$BIZ_HOST_SG_ID" \
        --protocol tcp --port 22 \
        --cidr "$ADMIN_CIDR" \
        --region "$AWS_REGION" 2>/dev/null || true

    test_save_var BIZ_HOST_SG_ID "$BIZ_HOST_SG_ID"
    log_info "Created business host SG: $BIZ_HOST_SG_ID"
fi

# UserData for business hosts
BIZ_USERDATA=$(cat <<'UDEOF'
#!/bin/bash
set -ex
yum install -y iperf3 nginx
systemctl enable nginx && systemctl start nginx
# Start iperf3 server in background (daemon mode)
iperf3 -s -D
UDEOF
)
BIZ_USERDATA_B64=$(echo "$BIZ_USERDATA" | base64 -w0)

# Launch business hosts
for i in $(seq 0 $((BIZ_HOST_COUNT - 1))); do
    VAR_ID="BIZ_HOST_ID_${i}"
    VAR_IP="BIZ_HOST_IP_${i}"

    if test_check_var_exists "$VAR_ID"; then
        log_info "Business host $i already exists: $(eval echo \$${VAR_ID})"
        continue
    fi

    # Round-robin subnet selection
    SUBNET_IDX=$((i % ${#BIZ_SUBNET_ARR[@]}))
    TARGET_SUBNET="${BIZ_SUBNET_ARR[$SUBNET_IDX]}"
    INSTANCE_NAME="dx-biz-host-${i}"

    log_info "Launching business host $i in subnet $TARGET_SUBNET"

    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$BIZ_HOST_INSTANCE_TYPE" \
        --key-name "$KEY_PAIR_NAME" \
        --security-group-ids "$BIZ_HOST_SG_ID" \
        --subnet-id "$TARGET_SUBNET" \
        --user-data "$BIZ_USERDATA_B64" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-biz}]" \
        --region "$AWS_REGION" \
        --query 'Instances[0].InstanceId' --output text)

    test_save_var "$VAR_ID" "$INSTANCE_ID"
    log_info "Launched business host $i: $INSTANCE_ID"
done

# Wait for all business hosts to be running and collect IPs
log_info "Waiting for business hosts to be running..."
for i in $(seq 0 $((BIZ_HOST_COUNT - 1))); do
    VAR_ID="BIZ_HOST_ID_${i}"
    VAR_IP="BIZ_HOST_IP_${i}"

    # Reload to pick up saved vars
    test_load_env
    INSTANCE_ID="${!VAR_ID}"

    log_info "Waiting for business host $i ($INSTANCE_ID)..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

    PRIVATE_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

    test_save_var "$VAR_IP" "$PRIVATE_IP"
    log_info "Business host $i: id=$INSTANCE_ID ip=$PRIVATE_IP"
done

# Summary
test_load_env
echo ""
log_info "===== Business Hosts Summary ====="
for i in $(seq 0 $((BIZ_HOST_COUNT - 1))); do
    VAR_ID="BIZ_HOST_ID_${i}"
    VAR_IP="BIZ_HOST_IP_${i}"
    log_info "  Host $i: ${!VAR_ID} (${!VAR_IP})"
done
log_info "==================================="
echo ""
log_info "Business hosts ready. Run 02-traffic-gen.sh next."
