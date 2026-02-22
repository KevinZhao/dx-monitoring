#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

require_vars VPC_ID VGW_ID BUSINESS_SUBNET_CIDRS GWLBE_SUBNETS

# ================================================================
# Create VGW Ingress Route Table
# ================================================================
log_info "=== Creating VGW Ingress Route Table ==="

if check_var_exists VGW_INGRESS_RTB_ID; then
    log_info "VGW Ingress route table already exists: ${VGW_INGRESS_RTB_ID}"
    RTB_ID="$VGW_INGRESS_RTB_ID"
else
    # Check by Name tag first
    existing=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
                  "Name=tag:Name,Values=dx-vgw-ingress-rt" \
        --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)

    if [[ -n "$existing" && "$existing" != "None" ]]; then
        RTB_ID="$existing"
        log_info "Found existing route table by Name tag: ${RTB_ID}"
    else
        RTB_ID=$(aws ec2 create-route-table \
            --vpc-id "$VPC_ID" \
            --query 'RouteTable.RouteTableId' --output text)
        log_info "Created route table: ${RTB_ID}"
    fi

    aws ec2 create-tags --resources "$RTB_ID" \
        --tags "Key=Name,Value=dx-vgw-ingress-rt"
    tag_resource "$RTB_ID"

    save_var VGW_INGRESS_RTB_ID "$RTB_ID"
fi

# ================================================================
# Edge Association: associate route table with VGW (not subnet)
# ================================================================
log_info "=== Creating Edge Association (VGW) ==="

if check_var_exists VGW_INGRESS_ASSOC_ID; then
    log_info "Edge association already exists: ${VGW_INGRESS_ASSOC_ID}"
else
    # Check if VGW already has an edge association with this route table
    existing_assoc=$(aws ec2 describe-route-tables \
        --route-table-ids "$RTB_ID" \
        --query "RouteTables[0].Associations[?GatewayId=='${VGW_ID}'].RouteTableAssociationId" \
        --output text 2>/dev/null || true)

    if [[ -n "$existing_assoc" && "$existing_assoc" != "None" && "$existing_assoc" != "" ]]; then
        ASSOC_ID="$existing_assoc"
        log_info "Edge association already exists: ${ASSOC_ID}"
    else
        ASSOC_ID=$(aws ec2 associate-route-table \
            --route-table-id "$RTB_ID" \
            --gateway-id "$VGW_ID" \
            --query 'AssociationId' --output text)
        log_info "Created edge association: ${ASSOC_ID}"
    fi

    save_var VGW_INGRESS_ASSOC_ID "$ASSOC_ID"
fi

# ================================================================
# Add routes: each BUSINESS_SUBNET_CIDR -> matching-AZ GWLBE
# ================================================================
log_info "=== Adding Business Subnet Routes ==="

# Build a map of AZ -> GWLBE_ID from GWLBE_SUBNETS
parse_subnets GWLBE_SUBNETS

declare -A GWLBE_AZ_MAP
GWLBE_INDEX=0
FIRST_GWLBE=""
for AZ in "${AZ_LIST[@]}"; do
    VAR_NAME="GWLBE_ID_${GWLBE_INDEX}"
    GWLBE_ID="${!VAR_NAME}"
    GWLBE_AZ_MAP["$AZ"]="$GWLBE_ID"
    if [[ -z "$FIRST_GWLBE" ]]; then
        FIRST_GWLBE="$GWLBE_ID"
    fi
    ((GWLBE_INDEX++))
done

# For each business CIDR, try to match AZ; fallback to first GWLBE
# We use round-robin across AZs for business CIDRs
IFS=',' read -ra CIDRS <<< "$BUSINESS_SUBNET_CIDRS"
AZ_COUNT=${#AZ_LIST[@]}
CIDR_INDEX=0

for CIDR in "${CIDRS[@]}"; do
    # Round-robin: pick AZ based on index
    AZ_IDX=$((CIDR_INDEX % AZ_COUNT))
    TARGET_AZ="${AZ_LIST[$AZ_IDX]}"
    TARGET_GWLBE="${GWLBE_AZ_MAP[$TARGET_AZ]:-$FIRST_GWLBE}"

    # Create or replace route
    aws ec2 create-route \
        --route-table-id "$RTB_ID" \
        --destination-cidr-block "$CIDR" \
        --vpc-endpoint-id "$TARGET_GWLBE" 2>/dev/null \
    || aws ec2 replace-route \
        --route-table-id "$RTB_ID" \
        --destination-cidr-block "$CIDR" \
        --vpc-endpoint-id "$TARGET_GWLBE"

    log_info "Route ${CIDR} -> ${TARGET_GWLBE} (${TARGET_AZ})"
    ((CIDR_INDEX++))
done

log_info "=== VGW Ingress Routing Complete ==="
log_info "  VGW_INGRESS_RTB_ID   = ${RTB_ID}"
log_info "  VGW_INGRESS_ASSOC_ID = $(eval echo \${VGW_INGRESS_ASSOC_ID})"
log_info "  Routes configured for ${#CIDRS[@]} business subnet CIDRs"
