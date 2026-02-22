#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

require_vars VPC_ID VPC_CIDR APPLIANCE_SUBNETS GWLBE_SUBNETS \
             APPLIANCE_SG_ID APPLIANCE_INSTANCE_TYPE KEY_PAIR_NAME AMI_ID

# ================================================================
# Step 2a: Launch Appliance Instances (1 per AZ)
# ================================================================
log_info "=== Step 2a: Launching Appliance Instances ==="

parse_subnets APPLIANCE_SUBNETS

USERDATA=$(cat <<'UDEOF'
#!/bin/bash
set -ex
yum install -y python3 python3-pip git
pip3 install gwlbtun
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/99-forwarding.conf

cat > /etc/systemd/system/gwlbtun.service <<'SVC'
[Unit]
Description=AWS GWLB Tunnel Handler
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gwlbtun
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now gwlbtun
UDEOF
)

USERDATA_B64=$(echo "$USERDATA" | base64 -w0)

INSTANCE_INDEX=0
APPLIANCE_INSTANCE_IDS=()

for AZ in "${AZ_LIST[@]}"; do
    SUBNET_ID="${SUBNET_MAP[$AZ]}"
    INSTANCE_NAME="dx-appliance-${AZ}"

    # Idempotency: check if instance already exists by Name tag
    existing=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

    if [[ -n "$existing" && "$existing" != "None" ]]; then
        log_info "Appliance instance ${INSTANCE_NAME} already exists: ${existing}"
        INSTANCE_ID="$existing"
    else
        INSTANCE_ID=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type "$APPLIANCE_INSTANCE_TYPE" \
            --key-name "$KEY_PAIR_NAME" \
            --subnet-id "$SUBNET_ID" \
            --security-group-ids "$APPLIANCE_SG_ID" \
            --user-data "$USERDATA_B64" \
            --tag-specifications \
                "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${PROJECT_TAG}}]" \
            --query 'Instances[0].InstanceId' --output text)

        log_info "Launched appliance instance ${INSTANCE_NAME}: ${INSTANCE_ID}"
    fi

    # Wait for instance to be running before modifying attributes
    log_info "Waiting for ${INSTANCE_ID} to reach running state..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

    # CRITICAL: disable source/dest check for forwarding
    aws ec2 modify-instance-attribute \
        --instance-id "$INSTANCE_ID" \
        --no-source-dest-check
    log_info "Disabled source/dest check on ${INSTANCE_ID}"

    save_var "APPLIANCE_INSTANCE_ID_${INSTANCE_INDEX}" "$INSTANCE_ID"
    APPLIANCE_INSTANCE_IDS+=("$INSTANCE_ID")
    ((INSTANCE_INDEX++))
done

log_info "Appliance instances launched: ${APPLIANCE_INSTANCE_IDS[*]}"

# ================================================================
# Step 2b: Create GWLB, Target Group, Register Targets, Listener
# ================================================================
log_info "=== Step 2b: Creating Gateway Load Balancer ==="

# Collect subnet IDs for GWLB
APPLIANCE_SUBNET_IDS=()
for AZ in "${AZ_LIST[@]}"; do
    APPLIANCE_SUBNET_IDS+=("${SUBNET_MAP[$AZ]}")
done

# Check if GWLB already exists
if check_var_exists GWLB_ARN; then
    log_info "GWLB already exists: ${GWLB_ARN}"
else
    GWLB_ARN=$(aws elbv2 create-load-balancer \
        --name dx-gwlb \
        --type gateway \
        --subnets "${APPLIANCE_SUBNET_IDS[@]}" \
        --tags "Key=Name,Value=dx-gwlb" "Key=Project,Value=${PROJECT_TAG}" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)

    save_var GWLB_ARN "$GWLB_ARN"
    log_info "Created GWLB: ${GWLB_ARN}"
fi

# Create Target Group
if check_var_exists GWLB_TG_ARN; then
    log_info "GWLB Target Group already exists: ${GWLB_TG_ARN}"
else
    GWLB_TG_ARN=$(aws elbv2 create-target-group \
        --name dx-gwlb-tg \
        --protocol GENEVE \
        --port 6081 \
        --vpc-id "$VPC_ID" \
        --target-type instance \
        --health-check-protocol TCP \
        --health-check-port 22 \
        --tags "Key=Name,Value=dx-gwlb-tg" "Key=Project,Value=${PROJECT_TAG}" \
        --query 'TargetGroups[0].TargetGroupArn' --output text)

    save_var GWLB_TG_ARN "$GWLB_TG_ARN"
    log_info "Created Target Group: ${GWLB_TG_ARN}"
fi

# Register appliance instances as targets
TARGETS=()
for iid in "${APPLIANCE_INSTANCE_IDS[@]}"; do
    TARGETS+=("Id=${iid}")
done

aws elbv2 register-targets \
    --target-group-arn "$GWLB_TG_ARN" \
    --targets "${TARGETS[@]}"
log_info "Registered ${#APPLIANCE_INSTANCE_IDS[@]} targets to GWLB TG"

# Create Listener
EXISTING_LISTENERS=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$GWLB_ARN" \
    --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)

if [[ -n "$EXISTING_LISTENERS" && "$EXISTING_LISTENERS" != "None" ]]; then
    log_info "GWLB Listener already exists"
else
    aws elbv2 create-listener \
        --load-balancer-arn "$GWLB_ARN" \
        --default-actions "Type=forward,TargetGroupArn=${GWLB_TG_ARN}" \
        --query 'Listeners[0].ListenerArn' --output text
    log_info "Created GWLB Listener"
fi

# Wait for GWLB to become active
log_info "Waiting for GWLB to become active..."
wait_for_state \
    "aws elbv2 describe-load-balancers --load-balancer-arns ${GWLB_ARN} --query LoadBalancers[0].State.Code --output text" \
    "active" \
    300

log_info "GWLB is active"

# ================================================================
# Step 2c: Create VPC Endpoint Service
# ================================================================
log_info "=== Step 2c: Creating VPC Endpoint Service ==="

if check_var_exists ENDPOINT_SERVICE_ID; then
    log_info "Endpoint Service already exists: ${ENDPOINT_SERVICE_ID}"
else
    EP_SVC_OUTPUT=$(aws ec2 create-vpc-endpoint-service-configuration \
        --gateway-load-balancer-arns "$GWLB_ARN" \
        --no-acceptance-required \
        --query 'ServiceConfiguration.[ServiceId,ServiceName]' --output text)

    ENDPOINT_SERVICE_ID=$(echo "$EP_SVC_OUTPUT" | awk '{print $1}')
    ENDPOINT_SERVICE_NAME=$(echo "$EP_SVC_OUTPUT" | awk '{print $2}')

    save_var ENDPOINT_SERVICE_ID "$ENDPOINT_SERVICE_ID"
    save_var ENDPOINT_SERVICE_NAME "$ENDPOINT_SERVICE_NAME"
    log_info "Created Endpoint Service: ${ENDPOINT_SERVICE_ID} (${ENDPOINT_SERVICE_NAME})"
fi

# Wait for endpoint service to become Available
log_info "Waiting for Endpoint Service to become available..."
wait_for_state \
    "aws ec2 describe-vpc-endpoint-service-configurations --service-ids ${ENDPOINT_SERVICE_ID} --query ServiceConfigurations[0].ServiceState --output text" \
    "Available" \
    300

log_info "Endpoint Service is available"

# ================================================================
# Step 2d: Create GWLBe (1 per AZ from GWLBE_SUBNETS)
# ================================================================
log_info "=== Step 2d: Creating GWLB Endpoints ==="

parse_subnets GWLBE_SUBNETS

GWLBE_INDEX=0
for AZ in "${AZ_LIST[@]}"; do
    SUBNET_ID="${SUBNET_MAP[$AZ]}"
    VAR_NAME="GWLBE_ID_${GWLBE_INDEX}"

    if check_var_exists "$VAR_NAME"; then
        log_info "GWLBE in ${AZ} already exists: $(eval echo \$${VAR_NAME})"
        ((GWLBE_INDEX++))
        continue
    fi

    GWLBE_ID=$(aws ec2 create-vpc-endpoint \
        --vpc-endpoint-type GatewayLoadBalancer \
        --service-name "$ENDPOINT_SERVICE_NAME" \
        --vpc-id "$VPC_ID" \
        --subnet-ids "$SUBNET_ID" \
        --query 'VpcEndpoint.VpcEndpointId' --output text)

    tag_resource "$GWLBE_ID"
    aws ec2 create-tags --resources "$GWLBE_ID" \
        --tags "Key=Name,Value=dx-gwlbe-${AZ}"

    save_var "$VAR_NAME" "$GWLBE_ID"
    log_info "Created GWLBE in ${AZ}: ${GWLBE_ID}"
    ((GWLBE_INDEX++))
done

# Wait for all endpoints to become available
log_info "Waiting for all GWLB Endpoints to become available..."
for i in $(seq 0 $((GWLBE_INDEX - 1))); do
    VAR_NAME="GWLBE_ID_${i}"
    GWLBE_ID=$(eval echo \$${VAR_NAME})
    wait_for_state \
        "aws ec2 describe-vpc-endpoints --vpc-endpoint-ids ${GWLBE_ID} --query VpcEndpoints[0].State --output text" \
        "available" \
        300
    log_info "GWLBE ${GWLBE_ID} is available"
done

log_info "=== GWLB + Appliance Setup Complete ==="
log_info "  GWLB_ARN             = ${GWLB_ARN}"
log_info "  GWLB_TG_ARN          = ${GWLB_TG_ARN}"
log_info "  ENDPOINT_SERVICE_ID   = ${ENDPOINT_SERVICE_ID}"
log_info "  ENDPOINT_SERVICE_NAME = ${ENDPOINT_SERVICE_NAME}"
log_info "  Appliance Instances   = ${APPLIANCE_INSTANCE_IDS[*]}"
