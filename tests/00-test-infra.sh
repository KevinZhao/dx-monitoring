#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/common.sh"
load_config
load_env

TEST_CONF="$SCRIPT_DIR/test-env.conf"
TEST_ENV_FILE="$SCRIPT_DIR/test-env-vars.sh"

if [[ ! -f "$TEST_CONF" ]]; then
    log_error "Test config not found: $TEST_CONF"
    exit 1
fi
source "$TEST_CONF"

# --- test variable persistence (separate from main env-vars.sh) ---

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

require_vars AWS_REGION VPC_ID VGW_ID VPC_CIDR PROJECT_TAG AMI_ID KEY_PAIR_NAME ADMIN_CIDR

# ================================================================
# Step 1: Create On-Prem Simulator VPC
# ================================================================
log_info "=== Step 1: Creating On-Prem Simulator VPC ==="

if test_check_var_exists ONPREM_VPC_ID; then
    log_info "On-prem VPC already exists: $ONPREM_VPC_ID"
else
    ONPREM_VPC_ID=$(aws ec2 create-vpc \
        --cidr-block "$ONPREM_VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=dx-test-onprem-vpc},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'Vpc.VpcId' --output text)

    aws ec2 modify-vpc-attribute --vpc-id "$ONPREM_VPC_ID" --enable-dns-support --region "$AWS_REGION"
    aws ec2 modify-vpc-attribute --vpc-id "$ONPREM_VPC_ID" --enable-dns-hostnames --region "$AWS_REGION"

    test_save_var ONPREM_VPC_ID "$ONPREM_VPC_ID"
    log_info "Created on-prem VPC: $ONPREM_VPC_ID"
fi

# Internet Gateway
if test_check_var_exists ONPREM_IGW_ID; then
    log_info "On-prem IGW already exists: $ONPREM_IGW_ID"
else
    ONPREM_IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=dx-test-onprem-igw},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'InternetGateway.InternetGatewayId' --output text)

    aws ec2 attach-internet-gateway \
        --internet-gateway-id "$ONPREM_IGW_ID" \
        --vpc-id "$ONPREM_VPC_ID" \
        --region "$AWS_REGION"

    test_save_var ONPREM_IGW_ID "$ONPREM_IGW_ID"
    log_info "Created and attached IGW: $ONPREM_IGW_ID"
fi

# Pick first AZ in the region
FIRST_AZ=$(aws ec2 describe-availability-zones \
    --region "$AWS_REGION" \
    --query 'AvailabilityZones[0].ZoneName' --output text)

# Public subnet (for CGW)
if test_check_var_exists ONPREM_PUBLIC_SUBNET_ID; then
    log_info "On-prem public subnet already exists: $ONPREM_PUBLIC_SUBNET_ID"
else
    ONPREM_PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id "$ONPREM_VPC_ID" \
        --cidr-block "$ONPREM_PUBLIC_SUBNET_CIDR" \
        --availability-zone "$FIRST_AZ" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=dx-test-onprem-public},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'Subnet.SubnetId' --output text)

    aws ec2 modify-subnet-attribute \
        --subnet-id "$ONPREM_PUBLIC_SUBNET_ID" \
        --map-public-ip-on-launch \
        --region "$AWS_REGION"

    test_save_var ONPREM_PUBLIC_SUBNET_ID "$ONPREM_PUBLIC_SUBNET_ID"
    log_info "Created public subnet: $ONPREM_PUBLIC_SUBNET_ID"
fi

# Private subnet (for traffic generators)
if test_check_var_exists ONPREM_PRIVATE_SUBNET_ID; then
    log_info "On-prem private subnet already exists: $ONPREM_PRIVATE_SUBNET_ID"
else
    ONPREM_PRIVATE_SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id "$ONPREM_VPC_ID" \
        --cidr-block "$ONPREM_PRIVATE_SUBNET_CIDR" \
        --availability-zone "$FIRST_AZ" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=dx-test-onprem-private},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'Subnet.SubnetId' --output text)

    test_save_var ONPREM_PRIVATE_SUBNET_ID "$ONPREM_PRIVATE_SUBNET_ID"
    log_info "Created private subnet: $ONPREM_PRIVATE_SUBNET_ID"
fi

# Public route table → IGW
if test_check_var_exists ONPREM_PUBLIC_RTB_ID; then
    log_info "On-prem public route table already exists: $ONPREM_PUBLIC_RTB_ID"
else
    ONPREM_PUBLIC_RTB_ID=$(aws ec2 create-route-table \
        --vpc-id "$ONPREM_VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=dx-test-onprem-public-rtb},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'RouteTable.RouteTableId' --output text)

    aws ec2 create-route \
        --route-table-id "$ONPREM_PUBLIC_RTB_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "$ONPREM_IGW_ID" \
        --region "$AWS_REGION" > /dev/null

    aws ec2 associate-route-table \
        --route-table-id "$ONPREM_PUBLIC_RTB_ID" \
        --subnet-id "$ONPREM_PUBLIC_SUBNET_ID" \
        --region "$AWS_REGION" > /dev/null

    test_save_var ONPREM_PUBLIC_RTB_ID "$ONPREM_PUBLIC_RTB_ID"
    log_info "Created public route table: $ONPREM_PUBLIC_RTB_ID"
fi

# NAT Gateway for private subnet
if test_check_var_exists ONPREM_NAT_GW_ID; then
    log_info "On-prem NAT Gateway already exists: $ONPREM_NAT_GW_ID"
else
    NAT_EIP_ALLOC=$(aws ec2 allocate-address \
        --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=dx-test-onprem-nat-eip},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'AllocationId' --output text)

    test_save_var ONPREM_NAT_EIP_ALLOC "$NAT_EIP_ALLOC"

    ONPREM_NAT_GW_ID=$(aws ec2 create-nat-gateway \
        --subnet-id "$ONPREM_PUBLIC_SUBNET_ID" \
        --allocation-id "$NAT_EIP_ALLOC" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=dx-test-onprem-nat},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'NatGateway.NatGatewayId' --output text)

    log_info "Waiting for NAT Gateway $ONPREM_NAT_GW_ID to become available..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$ONPREM_NAT_GW_ID" --region "$AWS_REGION"

    test_save_var ONPREM_NAT_GW_ID "$ONPREM_NAT_GW_ID"
    log_info "Created NAT Gateway: $ONPREM_NAT_GW_ID"
fi

# Private route table → NAT GW
if test_check_var_exists ONPREM_PRIVATE_RTB_ID; then
    log_info "On-prem private route table already exists: $ONPREM_PRIVATE_RTB_ID"
else
    ONPREM_PRIVATE_RTB_ID=$(aws ec2 create-route-table \
        --vpc-id "$ONPREM_VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=dx-test-onprem-private-rtb},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'RouteTable.RouteTableId' --output text)

    aws ec2 create-route \
        --route-table-id "$ONPREM_PRIVATE_RTB_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "$ONPREM_NAT_GW_ID" \
        --region "$AWS_REGION" > /dev/null

    aws ec2 associate-route-table \
        --route-table-id "$ONPREM_PRIVATE_RTB_ID" \
        --subnet-id "$ONPREM_PRIVATE_SUBNET_ID" \
        --region "$AWS_REGION" > /dev/null

    test_save_var ONPREM_PRIVATE_RTB_ID "$ONPREM_PRIVATE_RTB_ID"
    log_info "Created private route table: $ONPREM_PRIVATE_RTB_ID"
fi

# ================================================================
# Step 2: Launch CGW EC2 Instance
# ================================================================
log_info "=== Step 2: Launching CGW EC2 Instance ==="

# CGW Security Group
if test_check_var_exists CGW_SG_ID; then
    log_info "CGW security group already exists: $CGW_SG_ID"
else
    CGW_SG_ID=$(aws ec2 create-security-group \
        --group-name "dx-test-cgw-sg" \
        --description "DX Test - Customer Gateway (IPSec + SSH)" \
        --vpc-id "$ONPREM_VPC_ID" \
        --region "$AWS_REGION" \
        --query 'GroupId' --output text)

    aws ec2 create-tags --resources "$CGW_SG_ID" \
        --tags "Key=Name,Value=dx-test-cgw-sg" \
              "Key=Project,Value=${PROJECT_TAG}" \
              "Key=Role,Value=test-onprem" \
        --region "$AWS_REGION"

    # IPSec IKE
    aws ec2 authorize-security-group-ingress \
        --group-id "$CGW_SG_ID" \
        --protocol udp --port 500 \
        --cidr "0.0.0.0/0" \
        --region "$AWS_REGION" 2>/dev/null || true

    # IPSec NAT-T
    aws ec2 authorize-security-group-ingress \
        --group-id "$CGW_SG_ID" \
        --protocol udp --port 4500 \
        --cidr "0.0.0.0/0" \
        --region "$AWS_REGION" 2>/dev/null || true

    # SSH from admin
    aws ec2 authorize-security-group-ingress \
        --group-id "$CGW_SG_ID" \
        --protocol tcp --port 22 \
        --cidr "$ADMIN_CIDR" \
        --region "$AWS_REGION" 2>/dev/null || true

    # All traffic from on-prem VPC
    aws ec2 authorize-security-group-ingress \
        --group-id "$CGW_SG_ID" \
        --protocol all \
        --cidr "$ONPREM_VPC_CIDR" \
        --region "$AWS_REGION" 2>/dev/null || true

    test_save_var CGW_SG_ID "$CGW_SG_ID"
    log_info "Created CGW security group: $CGW_SG_ID"
fi

# CGW UserData
CGW_USERDATA=$(cat <<'UDEOF'
#!/bin/bash
set -ex
yum install -y libreswan
systemctl enable ipsec
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-vpn.conf
echo "net.ipv4.conf.default.rp_filter = 0" >> /etc/sysctl.d/99-vpn.conf
echo "net.ipv4.conf.all.rp_filter = 0" >> /etc/sysctl.d/99-vpn.conf
sysctl -p /etc/sysctl.d/99-vpn.conf
UDEOF
)
CGW_USERDATA_B64=$(echo "$CGW_USERDATA" | base64 -w0)

if test_check_var_exists CGW_INSTANCE_ID; then
    log_info "CGW instance already exists: $CGW_INSTANCE_ID"
else
    CGW_INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$CGW_INSTANCE_TYPE" \
        --key-name "$KEY_PAIR_NAME" \
        --security-group-ids "$CGW_SG_ID" \
        --subnet-id "$ONPREM_PUBLIC_SUBNET_ID" \
        --user-data "$CGW_USERDATA_B64" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=dx-test-cgw},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'Instances[0].InstanceId' --output text)

    test_save_var CGW_INSTANCE_ID "$CGW_INSTANCE_ID"
    log_info "Launched CGW instance: $CGW_INSTANCE_ID"
fi

log_info "Waiting for CGW instance $CGW_INSTANCE_ID to be running..."
aws ec2 wait instance-running --instance-ids "$CGW_INSTANCE_ID" --region "$AWS_REGION"

# Disable source/dest check for routing
aws ec2 modify-instance-attribute \
    --instance-id "$CGW_INSTANCE_ID" \
    --no-source-dest-check \
    --region "$AWS_REGION"
log_info "Disabled source/dest check on CGW instance"

# Allocate and associate EIP for CGW
if test_check_var_exists CGW_EIP_ALLOC; then
    log_info "CGW EIP already allocated: $CGW_EIP_ALLOC"
else
    CGW_EIP_ALLOC=$(aws ec2 allocate-address \
        --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=dx-test-cgw-eip},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'AllocationId' --output text)
    test_save_var CGW_EIP_ALLOC "$CGW_EIP_ALLOC"
fi

CGW_EIP=$(aws ec2 describe-addresses \
    --allocation-ids "$CGW_EIP_ALLOC" \
    --region "$AWS_REGION" \
    --query 'Addresses[0].PublicIp' --output text)

# Associate only if not already associated
CGW_EIP_ASSOC=$(aws ec2 describe-addresses \
    --allocation-ids "$CGW_EIP_ALLOC" \
    --region "$AWS_REGION" \
    --query 'Addresses[0].AssociationId' --output text)

if [[ "$CGW_EIP_ASSOC" == "None" || -z "$CGW_EIP_ASSOC" ]]; then
    aws ec2 associate-address \
        --instance-id "$CGW_INSTANCE_ID" \
        --allocation-id "$CGW_EIP_ALLOC" \
        --region "$AWS_REGION" > /dev/null
    log_info "Associated EIP $CGW_EIP with CGW instance"
fi

test_save_var CGW_EIP "$CGW_EIP"
log_info "CGW public IP: $CGW_EIP"

# Get CGW private IP and ENI for routing
CGW_PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids "$CGW_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
test_save_var CGW_PRIVATE_IP "$CGW_PRIVATE_IP"

CGW_ENI_ID=$(aws ec2 describe-instances \
    --instance-ids "$CGW_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
test_save_var CGW_ENI_ID "$CGW_ENI_ID"

# ================================================================
# Step 3: Create AWS Customer Gateway
# ================================================================
log_info "=== Step 3: Creating AWS Customer Gateway ==="

if test_check_var_exists CGW_ID; then
    log_info "Customer Gateway already exists: $CGW_ID"
else
    CGW_ID=$(aws ec2 create-customer-gateway \
        --type ipsec.1 \
        --public-ip "$CGW_EIP" \
        --bgp-asn 65000 \
        --tag-specifications "ResourceType=customer-gateway,Tags=[{Key=Name,Value=dx-test-cgw},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'CustomerGateway.CustomerGatewayId' --output text)

    test_save_var CGW_ID "$CGW_ID"
    log_info "Created Customer Gateway: $CGW_ID"
fi

# ================================================================
# Step 4: Create VPN Connection
# ================================================================
log_info "=== Step 4: Creating VPN Connection ==="

if test_check_var_exists VPN_ID; then
    log_info "VPN connection already exists: $VPN_ID"
else
    VPN_ID=$(aws ec2 create-vpn-connection \
        --type ipsec.1 \
        --customer-gateway-id "$CGW_ID" \
        --vpn-gateway-id "$VGW_ID" \
        --options '{"StaticRoutesOnly":true}' \
        --tag-specifications "ResourceType=vpn-connection,Tags=[{Key=Name,Value=dx-test-vpn},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'VpnConnection.VpnConnectionId' --output text)

    test_save_var VPN_ID "$VPN_ID"
    log_info "Created VPN connection: $VPN_ID"
fi

log_info "Waiting for VPN connection $VPN_ID to become available..."
wait_for_state \
    "aws ec2 describe-vpn-connections --vpn-connection-ids ${VPN_ID} --region ${AWS_REGION} --query VpnConnections[0].State --output text" \
    "available" \
    600

# Create static route for on-prem CIDR
aws ec2 create-vpn-connection-route \
    --vpn-connection-id "$VPN_ID" \
    --destination-cidr-block "$ONPREM_VPC_CIDR" \
    --region "$AWS_REGION" 2>/dev/null || log_warn "VPN static route already exists"

log_info "VPN connection available with static route for $ONPREM_VPC_CIDR"

# ================================================================
# Step 5: Configure Libreswan on CGW EC2
# ================================================================
log_info "=== Step 5: Configuring Libreswan on CGW EC2 ==="

VPN_CONFIG=$(aws ec2 describe-vpn-connections \
    --vpn-connection-ids "$VPN_ID" \
    --region "$AWS_REGION" \
    --output json)

TUNNEL1_OUTSIDE_IP=$(echo "$VPN_CONFIG" | jq -r '.VpnConnections[0].Options.TunnelOptions[0].OutsideIpAddress')
TUNNEL1_PSK=$(echo "$VPN_CONFIG" | jq -r '.VpnConnections[0].Options.TunnelOptions[0].PreSharedKey')
TUNNEL1_INSIDE_CIDR=$(echo "$VPN_CONFIG" | jq -r '.VpnConnections[0].Options.TunnelOptions[0].TunnelInsideCidr')

if [[ -z "$TUNNEL1_OUTSIDE_IP" || "$TUNNEL1_OUTSIDE_IP" == "null" ]]; then
    log_error "Failed to extract tunnel info from VPN connection"
    exit 1
fi

test_save_var TUNNEL1_OUTSIDE_IP "$TUNNEL1_OUTSIDE_IP"
log_info "Tunnel1 outside IP: $TUNNEL1_OUTSIDE_IP"
log_info "Tunnel1 inside CIDR: $TUNNEL1_INSIDE_CIDR"

# Wait for CGW instance to pass status checks (SSH readiness)
log_info "Waiting for CGW instance status checks..."
aws ec2 wait instance-status-ok --instance-ids "$CGW_INSTANCE_ID" --region "$AWS_REGION"

# Build Libreswan config
IPSEC_CONF="conn aws-vpn-tunnel1
    type=tunnel
    authby=secret
    left=%defaultroute
    leftid=${CGW_EIP}
    right=${TUNNEL1_OUTSIDE_IP}
    rightid=${TUNNEL1_OUTSIDE_IP}
    auto=start
    ike=aes256-sha256;modp2048
    phase2alg=aes256-sha256;modp2048
    ikelifetime=8h
    salifetime=1h
    leftsubnet=${ONPREM_VPC_CIDR}
    rightsubnet=${VPC_CIDR}"

IPSEC_SECRETS="${CGW_EIP} ${TUNNEL1_OUTSIDE_IP} : PSK \"${TUNNEL1_PSK}\""

# Deploy config via SSM (avoids SSH key dependency)
log_info "Deploying Libreswan config via SSM..."

IPSEC_CONF_ESCAPED=$(echo "$IPSEC_CONF" | sed 's/"/\\"/g')
IPSEC_SECRETS_ESCAPED=$(echo "$IPSEC_SECRETS" | sed 's/"/\\"/g')

SSM_COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$CGW_INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[
        \"cat > /etc/ipsec.d/aws-vpn.conf << 'VPNCONF'\n${IPSEC_CONF}\nVPNCONF\",
        \"cat > /etc/ipsec.d/aws-vpn.secrets << 'VPNSEC'\n${IPSEC_SECRETS}\nVPNSEC\",
        \"chmod 600 /etc/ipsec.d/aws-vpn.secrets\",
        \"systemctl restart ipsec\",
        \"sleep 10\",
        \"ipsec status\"
    ]}" \
    --region "$AWS_REGION" \
    --query 'Command.CommandId' --output text)

log_info "SSM command sent: $SSM_COMMAND_ID"

# Wait for SSM command to complete
log_info "Waiting for Libreswan configuration to complete..."
aws ssm wait command-executed \
    --command-id "$SSM_COMMAND_ID" \
    --instance-id "$CGW_INSTANCE_ID" \
    --region "$AWS_REGION" 2>/dev/null || true

SSM_STATUS=$(aws ssm get-command-invocation \
    --command-id "$SSM_COMMAND_ID" \
    --instance-id "$CGW_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Status' --output text)

if [[ "$SSM_STATUS" != "Success" ]]; then
    log_warn "SSM command status: $SSM_STATUS (Libreswan may need manual verification)"
    SSM_OUTPUT=$(aws ssm get-command-invocation \
        --command-id "$SSM_COMMAND_ID" \
        --instance-id "$CGW_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'StandardErrorContent' --output text)
    log_warn "SSM stderr: $SSM_OUTPUT"
else
    log_info "Libreswan configured and restarted successfully"
fi

# Add route on CGW for monitoring VPC via tunnel
SSM_ROUTE_CMD=$(aws ssm send-command \
    --instance-ids "$CGW_INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[
        \"ip route add ${VPC_CIDR} dev vti1 2>/dev/null || ip route replace ${VPC_CIDR} dev vti1 2>/dev/null || echo 'Route via VTI not needed (Libreswan handles routing)'\"
    ]}" \
    --region "$AWS_REGION" \
    --query 'Command.CommandId' --output text)

log_info "Route command sent: $SSM_ROUTE_CMD"

# ================================================================
# Step 6: Update On-Prem Private Subnet Routing
# ================================================================
log_info "=== Step 6: Updating On-Prem Private Subnet Routing ==="

# Route monitoring VPC CIDR through CGW ENI
EXISTING_ROUTE=$(aws ec2 describe-route-tables \
    --route-table-ids "$ONPREM_PRIVATE_RTB_ID" \
    --region "$AWS_REGION" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='${VPC_CIDR}'].DestinationCidrBlock" \
    --output text)

if [[ -n "$EXISTING_ROUTE" && "$EXISTING_ROUTE" != "None" ]]; then
    log_info "Route to $VPC_CIDR already exists in private route table"
else
    aws ec2 create-route \
        --route-table-id "$ONPREM_PRIVATE_RTB_ID" \
        --destination-cidr-block "$VPC_CIDR" \
        --network-interface-id "$CGW_ENI_ID" \
        --region "$AWS_REGION" > /dev/null
    log_info "Added route $VPC_CIDR -> CGW ENI in private route table"
fi

# ================================================================
# Step 7: Verify Main VPC Has Return Route
# ================================================================
log_info "=== Step 7: Verifying Main VPC Return Route ==="

# VGW route propagation should handle this, but let's verify
# Get route tables associated with business subnets
BUSINESS_RTBS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=tag:Project,Values=${PROJECT_TAG}" \
    --region "$AWS_REGION" \
    --query 'RouteTables[].RouteTableId' --output text)

FOUND_RETURN_ROUTE=false
for RTB_ID in $BUSINESS_RTBS; do
    RETURN_ROUTE=$(aws ec2 describe-route-tables \
        --route-table-ids "$RTB_ID" \
        --region "$AWS_REGION" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='${ONPREM_VPC_CIDR}' && GatewayId=='${VGW_ID}'].DestinationCidrBlock" \
        --output text 2>/dev/null || true)

    if [[ -n "$RETURN_ROUTE" && "$RETURN_ROUTE" != "None" ]]; then
        FOUND_RETURN_ROUTE=true
        log_info "Return route to $ONPREM_VPC_CIDR via VGW found in $RTB_ID"
        break
    fi
done

if [[ "$FOUND_RETURN_ROUTE" == "false" ]]; then
    log_warn "No return route to $ONPREM_VPC_CIDR found via VGW in any business route table"
    log_warn "Ensure VGW route propagation is enabled on business subnet route tables"
    log_warn "Or manually add: $ONPREM_VPC_CIDR -> $VGW_ID"
fi

# ================================================================
# Summary
# ================================================================
test_load_env
echo ""
log_info "===== Test Infrastructure Summary ====="
log_info "On-Prem VPC:          $ONPREM_VPC_ID"
log_info "On-Prem Public Subnet: $ONPREM_PUBLIC_SUBNET_ID"
log_info "On-Prem Private Subnet: $ONPREM_PRIVATE_SUBNET_ID"
log_info "CGW Instance:          $CGW_INSTANCE_ID ($CGW_EIP)"
log_info "Customer Gateway:      $CGW_ID"
log_info "VPN Connection:        $VPN_ID"
log_info "Tunnel1 Outside IP:    $TUNNEL1_OUTSIDE_IP"
log_info "Test env file:         $TEST_ENV_FILE"
log_info "========================================"
echo ""
log_info "Test infrastructure ready. Run 01-business-hosts.sh next."
