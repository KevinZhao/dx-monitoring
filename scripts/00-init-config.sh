#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_config

# Validate DEPLOY_MODE
DEPLOY_MODE="${DEPLOY_MODE:-gwlb}"
if [[ "$DEPLOY_MODE" != "gwlb" && "$DEPLOY_MODE" != "direct" ]]; then
    log_error "Invalid DEPLOY_MODE='$DEPLOY_MODE'. Must be 'gwlb' or 'direct'"
    exit 1
fi
log_info "Deploy mode: $DEPLOY_MODE"

# Validate AWS credentials
log_info "Validating AWS credentials..."
CALLER_IDENTITY=$(aws sts get-caller-identity --region "$AWS_REGION" --output json)
ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
CALLER_ARN=$(echo "$CALLER_IDENTITY" | jq -r '.Arn')
log_info "AWS Account: $ACCOUNT_ID ($CALLER_ARN)"

# Validate VPC exists
log_info "Validating VPC $VPC_ID..."
VPC_STATE=$(aws ec2 describe-vpcs \
    --vpc-ids "$VPC_ID" \
    --region "$AWS_REGION" \
    --query "Vpcs[0].State" \
    --output text)
if [[ "$VPC_STATE" != "available" ]]; then
    log_error "VPC $VPC_ID is not available (state: $VPC_STATE)"
    exit 1
fi
log_info "VPC $VPC_ID is available"

# Validate VGW exists and is attached to VPC
log_info "Validating VGW $VGW_ID..."
VGW_INFO=$(aws ec2 describe-vpn-gateways \
    --vpn-gateway-ids "$VGW_ID" \
    --region "$AWS_REGION" \
    --output json)

ATTACHED_VPC=$(echo "$VGW_INFO" | jq -r ".VpnGateways[0].VpcAttachments[] | select(.VpcId==\"$VPC_ID\") | .State")
if [[ "$ATTACHED_VPC" != "attached" ]]; then
    log_error "VGW $VGW_ID is not attached to VPC $VPC_ID (state: ${ATTACHED_VPC:-not found})"
    exit 1
fi
log_info "VGW $VGW_ID is attached to VPC $VPC_ID"

# Resolve latest AL2023 ARM64 AMI
log_info "Resolving latest AL2023 ARM64 AMI..."
AMI_ID=$(get_latest_ami)
if [[ -z "$AMI_ID" ]]; then
    log_error "Failed to resolve AMI"
    exit 1
fi
log_info "Resolved AMI: $AMI_ID"

# Initialize env-vars.sh
echo "# dx-monitoring environment variables" > "$ENV_FILE"
echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$ENV_FILE"
echo "" >> "$ENV_FILE"

save_var AMI_ID "$AMI_ID"

# Print summary
echo ""
log_info "===== Configuration Summary ====="
log_info "Deploy Mode:     $DEPLOY_MODE"
log_info "AWS Region:      $AWS_REGION"
log_info "AWS Account:     $ACCOUNT_ID"
log_info "VPC:             $VPC_ID"
log_info "VGW:             $VGW_ID"
log_info "VPC CIDR:        $VPC_CIDR"
log_info "AMI ID:          $AMI_ID"
log_info "Project Tag:     $PROJECT_TAG"
log_info "Env file:        $ENV_FILE"
log_info "================================="
echo ""
log_info "Initialization complete. Run the next script to continue."
