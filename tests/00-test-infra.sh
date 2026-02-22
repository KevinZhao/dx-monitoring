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
    log_info "Saved $name=$value"
}

test_load_env() {
    if [[ -f "$TEST_ENV_FILE" ]]; then
        source "$TEST_ENV_FILE"
    fi
}

test_check_var_exists() {
    [[ -f "$TEST_ENV_FILE" ]] && grep -q "^${1}=" "$TEST_ENV_FILE" 2>/dev/null
}

test_load_env

require_vars AWS_REGION VPC_ID VGW_ID VPC_CIDR PROJECT_TAG AMI_ID KEY_PAIR_NAME ADMIN_CIDR

# ================================================================
# Step 1: Create On-Prem Simulator VPC (单一公有子网, 无 NAT GW)
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
        --internet-gateway-id "$ONPREM_IGW_ID" --vpc-id "$ONPREM_VPC_ID" --region "$AWS_REGION"
    test_save_var ONPREM_IGW_ID "$ONPREM_IGW_ID"
fi

# 单一公有子网 (CGW + 流量发生器共用)
FIRST_AZ=$(aws ec2 describe-availability-zones \
    --region "$AWS_REGION" --query 'AvailabilityZones[0].ZoneName' --output text)

if test_check_var_exists ONPREM_SUBNET_ID; then
    log_info "On-prem subnet already exists: $ONPREM_SUBNET_ID"
else
    ONPREM_SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id "$ONPREM_VPC_ID" \
        --cidr-block "$ONPREM_SUBNET_CIDR" \
        --availability-zone "$FIRST_AZ" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=dx-test-onprem-subnet},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'Subnet.SubnetId' --output text)
    aws ec2 modify-subnet-attribute \
        --subnet-id "$ONPREM_SUBNET_ID" --map-public-ip-on-launch --region "$AWS_REGION"
    test_save_var ONPREM_SUBNET_ID "$ONPREM_SUBNET_ID"
fi

# Route table -> IGW
if test_check_var_exists ONPREM_RTB_ID; then
    log_info "On-prem route table already exists: $ONPREM_RTB_ID"
else
    ONPREM_RTB_ID=$(aws ec2 create-route-table \
        --vpc-id "$ONPREM_VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=dx-test-onprem-rtb},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route \
        --route-table-id "$ONPREM_RTB_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "$ONPREM_IGW_ID" \
        --region "$AWS_REGION" > /dev/null
    aws ec2 associate-route-table \
        --route-table-id "$ONPREM_RTB_ID" \
        --subnet-id "$ONPREM_SUBNET_ID" \
        --region "$AWS_REGION" > /dev/null
    test_save_var ONPREM_RTB_ID "$ONPREM_RTB_ID"
fi

# ================================================================
# Step 2: Launch CGW EC2 Instance
# ================================================================
log_info "=== Step 2: Launching CGW EC2 Instance ==="

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
        --tags "Key=Name,Value=dx-test-cgw-sg" "Key=Project,Value=${PROJECT_TAG}" "Key=Role,Value=test-onprem" \
        --region "$AWS_REGION"
    # IPSec IKE + NAT-T
    aws ec2 authorize-security-group-ingress --group-id "$CGW_SG_ID" \
        --protocol udp --port 500 --cidr "0.0.0.0/0" --region "$AWS_REGION" 2>/dev/null || true
    aws ec2 authorize-security-group-ingress --group-id "$CGW_SG_ID" \
        --protocol udp --port 4500 --cidr "0.0.0.0/0" --region "$AWS_REGION" 2>/dev/null || true
    # SSH
    aws ec2 authorize-security-group-ingress --group-id "$CGW_SG_ID" \
        --protocol tcp --port 22 --cidr "$ADMIN_CIDR" --region "$AWS_REGION" 2>/dev/null || true
    # All from on-prem VPC
    aws ec2 authorize-security-group-ingress --group-id "$CGW_SG_ID" \
        --protocol all --cidr "$ONPREM_VPC_CIDR" --region "$AWS_REGION" 2>/dev/null || true
    test_save_var CGW_SG_ID "$CGW_SG_ID"
fi

CGW_USERDATA=$(base64 -w0 <<'UDEOF'
#!/bin/bash
set -ex
yum install -y libreswan
systemctl enable ipsec
cat >> /etc/sysctl.d/99-vpn.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.rp_filter = 0
EOF
sysctl -p /etc/sysctl.d/99-vpn.conf
UDEOF
)

if test_check_var_exists CGW_INSTANCE_ID; then
    log_info "CGW instance already exists: $CGW_INSTANCE_ID"
else
    CGW_INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$CGW_INSTANCE_TYPE" \
        --key-name "$KEY_PAIR_NAME" \
        --security-group-ids "$CGW_SG_ID" \
        --subnet-id "$ONPREM_SUBNET_ID" \
        --user-data "$CGW_USERDATA" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=dx-test-cgw},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" \
        --query 'Instances[0].InstanceId' --output text)
    test_save_var CGW_INSTANCE_ID "$CGW_INSTANCE_ID"
fi

log_info "Waiting for CGW instance to be running..."
aws ec2 wait instance-running --instance-ids "$CGW_INSTANCE_ID" --region "$AWS_REGION"

# Disable source/dest check for routing
aws ec2 modify-instance-attribute \
    --instance-id "$CGW_INSTANCE_ID" --no-source-dest-check --region "$AWS_REGION"

# EIP for CGW (VPN requires public IP)
if test_check_var_exists CGW_EIP_ALLOC; then
    log_info "CGW EIP already allocated: $CGW_EIP_ALLOC"
else
    CGW_EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=dx-test-cgw-eip},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" --query 'AllocationId' --output text)
    test_save_var CGW_EIP_ALLOC "$CGW_EIP_ALLOC"
fi

CGW_EIP=$(aws ec2 describe-addresses --allocation-ids "$CGW_EIP_ALLOC" \
    --region "$AWS_REGION" --query 'Addresses[0].PublicIp' --output text)

CGW_EIP_ASSOC=$(aws ec2 describe-addresses --allocation-ids "$CGW_EIP_ALLOC" \
    --region "$AWS_REGION" --query 'Addresses[0].AssociationId' --output text)

if [[ "$CGW_EIP_ASSOC" == "None" || -z "$CGW_EIP_ASSOC" ]]; then
    aws ec2 associate-address \
        --instance-id "$CGW_INSTANCE_ID" --allocation-id "$CGW_EIP_ALLOC" --region "$AWS_REGION" > /dev/null
fi

test_save_var CGW_EIP "$CGW_EIP"

CGW_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$CGW_INSTANCE_ID" \
    --region "$AWS_REGION" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
test_save_var CGW_PRIVATE_IP "$CGW_PRIVATE_IP"

CGW_ENI_ID=$(aws ec2 describe-instances --instance-ids "$CGW_INSTANCE_ID" \
    --region "$AWS_REGION" --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
test_save_var CGW_ENI_ID "$CGW_ENI_ID"

# ================================================================
# Step 3: Create AWS Customer Gateway
# ================================================================
log_info "=== Step 3: Creating AWS Customer Gateway ==="

if test_check_var_exists CGW_ID; then
    log_info "Customer Gateway already exists: $CGW_ID"
else
    CGW_ID=$(aws ec2 create-customer-gateway \
        --type ipsec.1 --public-ip "$CGW_EIP" --bgp-asn 65000 \
        --tag-specifications "ResourceType=customer-gateway,Tags=[{Key=Name,Value=dx-test-cgw},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" --query 'CustomerGateway.CustomerGatewayId' --output text)
    test_save_var CGW_ID "$CGW_ID"
fi

# ================================================================
# Step 4: Create VPN Connection (static routing)
# ================================================================
log_info "=== Step 4: Creating VPN Connection ==="

if test_check_var_exists VPN_ID; then
    log_info "VPN connection already exists: $VPN_ID"
else
    VPN_ID=$(aws ec2 create-vpn-connection \
        --type ipsec.1 --customer-gateway-id "$CGW_ID" --vpn-gateway-id "$VGW_ID" \
        --options '{"StaticRoutesOnly":true}' \
        --tag-specifications "ResourceType=vpn-connection,Tags=[{Key=Name,Value=dx-test-vpn},{Key=Project,Value=${PROJECT_TAG}},{Key=Role,Value=test-onprem}]" \
        --region "$AWS_REGION" --query 'VpnConnection.VpnConnectionId' --output text)
    test_save_var VPN_ID "$VPN_ID"
fi

log_info "Waiting for VPN connection to become available..."
wait_for_state \
    "aws ec2 describe-vpn-connections --vpn-connection-ids ${VPN_ID} --region ${AWS_REGION} --query VpnConnections[0].State --output text" \
    "available" 600

aws ec2 create-vpn-connection-route \
    --vpn-connection-id "$VPN_ID" --destination-cidr-block "$ONPREM_VPC_CIDR" \
    --region "$AWS_REGION" 2>/dev/null || log_warn "VPN static route already exists"

# ================================================================
# Step 5: Configure Libreswan on CGW EC2 via SSM
# ================================================================
log_info "=== Step 5: Configuring Libreswan ==="

VPN_CONFIG=$(aws ec2 describe-vpn-connections \
    --vpn-connection-ids "$VPN_ID" --region "$AWS_REGION" --output json)

TUNNEL1_OUTSIDE_IP=$(echo "$VPN_CONFIG" | jq -r '.VpnConnections[0].Options.TunnelOptions[0].OutsideIpAddress')
TUNNEL1_PSK=$(echo "$VPN_CONFIG" | jq -r '.VpnConnections[0].Options.TunnelOptions[0].PreSharedKey')
TUNNEL1_INSIDE_CIDR=$(echo "$VPN_CONFIG" | jq -r '.VpnConnections[0].Options.TunnelOptions[0].TunnelInsideCidr')

if [[ -z "$TUNNEL1_OUTSIDE_IP" || "$TUNNEL1_OUTSIDE_IP" == "null" ]]; then
    log_error "Failed to extract tunnel info from VPN connection"
    exit 1
fi
test_save_var TUNNEL1_OUTSIDE_IP "$TUNNEL1_OUTSIDE_IP"
log_info "Tunnel1: outside=$TUNNEL1_OUTSIDE_IP inside=$TUNNEL1_INSIDE_CIDR"

log_info "Waiting for CGW instance status checks (SSH/SSM readiness)..."
aws ec2 wait instance-status-ok --instance-ids "$CGW_INSTANCE_ID" --region "$AWS_REGION"

SSM_COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$CGW_INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[
        \"cat > /etc/ipsec.d/aws-vpn.conf << 'VPNEOF'\nconn aws-vpn-tunnel1\n    type=tunnel\n    authby=secret\n    left=%defaultroute\n    leftid=${CGW_EIP}\n    right=${TUNNEL1_OUTSIDE_IP}\n    rightid=${TUNNEL1_OUTSIDE_IP}\n    auto=start\n    ike=aes256-sha256;modp2048\n    phase2alg=aes256-sha256;modp2048\n    ikelifetime=8h\n    salifetime=1h\n    leftsubnet=${ONPREM_VPC_CIDR}\n    rightsubnet=${VPC_CIDR}\nVPNEOF\",
        \"cat > /etc/ipsec.d/aws-vpn.secrets << 'SECEOF'\n${CGW_EIP} ${TUNNEL1_OUTSIDE_IP} : PSK \\\"${TUNNEL1_PSK}\\\"\nSECEOF\",
        \"chmod 600 /etc/ipsec.d/aws-vpn.secrets\",
        \"systemctl restart ipsec\",
        \"sleep 10\",
        \"ipsec status\"
    ]}" \
    --region "$AWS_REGION" --query 'Command.CommandId' --output text)

log_info "Waiting for Libreswan configuration (SSM: $SSM_COMMAND_ID)..."
aws ssm wait command-executed \
    --command-id "$SSM_COMMAND_ID" --instance-id "$CGW_INSTANCE_ID" \
    --region "$AWS_REGION" 2>/dev/null || true

SSM_STATUS=$(aws ssm get-command-invocation \
    --command-id "$SSM_COMMAND_ID" --instance-id "$CGW_INSTANCE_ID" \
    --region "$AWS_REGION" --query 'Status' --output text)

if [[ "$SSM_STATUS" != "Success" ]]; then
    log_warn "SSM command status: $SSM_STATUS (may need manual verification)"
else
    log_info "Libreswan configured and restarted"
fi

# ================================================================
# Step 6: Update routing - on-prem subnet -> monitoring VPC via CGW
# ================================================================
log_info "=== Step 6: Updating On-Prem Routing ==="

EXISTING_ROUTE=$(aws ec2 describe-route-tables --route-table-ids "$ONPREM_RTB_ID" \
    --region "$AWS_REGION" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='${VPC_CIDR}'].DestinationCidrBlock" --output text)

if [[ -n "$EXISTING_ROUTE" && "$EXISTING_ROUTE" != "None" ]]; then
    log_info "Route to $VPC_CIDR already exists"
else
    aws ec2 create-route --route-table-id "$ONPREM_RTB_ID" \
        --destination-cidr-block "$VPC_CIDR" \
        --network-interface-id "$CGW_ENI_ID" \
        --region "$AWS_REGION" > /dev/null
    log_info "Added route $VPC_CIDR -> CGW ENI"
fi

# ================================================================
# Step 7: Verify main VPC has return route via VGW
# ================================================================
log_info "=== Step 7: Enabling VGW Route Propagation + Verifying Return Route ==="

BUSINESS_RTBS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --region "$AWS_REGION" --query 'RouteTables[].RouteTableId' --output text)

# Enable VGW route propagation on all route tables in monitoring VPC
for RTB_ID in $BUSINESS_RTBS; do
    aws ec2 enable-vgw-route-propagation \
        --route-table-id "$RTB_ID" --gateway-id "$VGW_ID" \
        --region "$AWS_REGION" 2>/dev/null || true
    log_info "Enabled VGW route propagation on $RTB_ID"
done

# Wait for propagation
sleep 5

FOUND_RETURN=false
for RTB_ID in $BUSINESS_RTBS; do
    RETURN_ROUTE=$(aws ec2 describe-route-tables --route-table-ids "$RTB_ID" \
        --region "$AWS_REGION" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='${ONPREM_VPC_CIDR}' && GatewayId=='${VGW_ID}'].DestinationCidrBlock" \
        --output text 2>/dev/null || true)
    if [[ -n "$RETURN_ROUTE" && "$RETURN_ROUTE" != "None" ]]; then
        FOUND_RETURN=true
        log_info "Return route to $ONPREM_VPC_CIDR via VGW confirmed in $RTB_ID"
        break
    fi
done

if [[ "$FOUND_RETURN" == "false" ]]; then
    log_warn "Return route to $ONPREM_VPC_CIDR not yet propagated. VPN may need more time."
fi

# ================================================================
# Summary
# ================================================================
test_load_env
echo ""
log_info "===== Test Infrastructure Summary ====="
log_info "On-Prem VPC:     $ONPREM_VPC_ID ($ONPREM_VPC_CIDR)"
log_info "On-Prem Subnet:  $ONPREM_SUBNET_ID ($ONPREM_SUBNET_CIDR)"
log_info "CGW Instance:    $CGW_INSTANCE_ID (EIP: $CGW_EIP)"
log_info "Customer Gateway: $CGW_ID"
log_info "VPN Connection:  $VPN_ID"
log_info "Tunnel1 Outside: $TUNNEL1_OUTSIDE_IP"
log_info "========================================"
