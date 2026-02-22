#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/scripts/lib/common.sh"
load_config

# Source test environment
TEST_ENV_FILE="$SCRIPT_DIR/test-env-vars.sh"
if [[ ! -f "$TEST_ENV_FILE" ]]; then
    log_warn "Test env file not found: $TEST_ENV_FILE - nothing to clean up"
    exit 0
fi
source "$TEST_ENV_FILE"

FORCE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
fi

if [[ "$FORCE" != "true" ]]; then
    echo "This will delete ALL test resources. Type 'yes' to confirm:"
    read -r CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
fi

cleanup_step() {
    local desc="$1"
    shift
    log_info "Cleaning up: $desc"
    "$@" || true
}

# 1. Terminate traffic-gen instances
TERM_IDS=()
while IFS='=' read -r VAR_NAME VAR_VAL; do
    [[ -z "$VAR_NAME" ]] && continue
    VAR_VAL="${VAR_VAL//\"/}"
    if [[ -n "$VAR_VAL" ]]; then
        log_info "Terminating traffic-gen: $VAR_VAL"
        TERM_IDS+=("$VAR_VAL")
    fi
done < <(grep "^TRAFFIC_GEN_ID_" "$TEST_ENV_FILE" 2>/dev/null || true)
if [[ ${#TERM_IDS[@]} -gt 0 ]]; then
    cleanup_step "Traffic-gen instances (${TERM_IDS[*]})" \
        aws ec2 terminate-instances --instance-ids "${TERM_IDS[@]}" --region "${AWS_REGION}"
fi

# 2. Terminate business host instances
BIZ_IDS=()
while IFS='=' read -r VAR_NAME VAR_VAL; do
    [[ -z "$VAR_NAME" ]] && continue
    VAR_VAL="${VAR_VAL//\"/}"
    if [[ -n "$VAR_VAL" ]]; then
        log_info "Terminating biz-host: $VAR_VAL"
        BIZ_IDS+=("$VAR_VAL")
    fi
done < <(grep "^BIZ_HOST_ID_" "$TEST_ENV_FILE" 2>/dev/null || true)
if [[ ${#BIZ_IDS[@]} -gt 0 ]]; then
    cleanup_step "Business host instances (${BIZ_IDS[*]})" \
        aws ec2 terminate-instances --instance-ids "${BIZ_IDS[@]}" --region "${AWS_REGION}"
fi

# 3. Delete VPN Connection
if [[ -n "${VPN_ID:-}" ]]; then
    cleanup_step "VPN connection $VPN_ID" \
        aws ec2 delete-vpn-connection --vpn-connection-id "$VPN_ID" --region "${AWS_REGION}"
    log_info "Waiting for VPN connection to be deleted..."
    aws ec2 wait vpn-connection-deleted --vpn-connection-ids "$VPN_ID" --region "${AWS_REGION}" 2>/dev/null || true
fi

# 4. Delete Customer Gateway
if [[ -n "${CGW_ID:-}" ]]; then
    cleanup_step "Customer gateway $CGW_ID" \
        aws ec2 delete-customer-gateway --customer-gateway-id "$CGW_ID" --region "${AWS_REGION}"
fi

# 5. Terminate CGW instance
CGW_INST_IDS=()
if [[ -n "${CGW_INSTANCE_ID:-}" ]]; then
    log_info "Terminating CGW instance: $CGW_INSTANCE_ID"
    CGW_INST_IDS+=("$CGW_INSTANCE_ID")
    cleanup_step "CGW instance $CGW_INSTANCE_ID" \
        aws ec2 terminate-instances --instance-ids "$CGW_INSTANCE_ID" --region "${AWS_REGION}"
fi

# 6. Release CGW EIP
if [[ -n "${CGW_EIP_ALLOC:-}" ]]; then
    cleanup_step "CGW EIP $CGW_EIP_ALLOC" \
        aws ec2 release-address --allocation-id "$CGW_EIP_ALLOC" --region "${AWS_REGION}"
fi

# 7. Delete NAT Gateway
if [[ -n "${ONPREM_NAT_GW_ID:-}" ]]; then
    cleanup_step "NAT gateway $ONPREM_NAT_GW_ID" \
        aws ec2 delete-nat-gateway --nat-gateway-id "$ONPREM_NAT_GW_ID" --region "${AWS_REGION}"
    log_info "Waiting for NAT gateway to be deleted..."
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$ONPREM_NAT_GW_ID" --region "${AWS_REGION}" 2>/dev/null || true
fi

# 8. Release NAT EIP
if [[ -n "${ONPREM_NAT_EIP_ALLOC:-}" ]]; then
    cleanup_step "NAT EIP $ONPREM_NAT_EIP_ALLOC" \
        aws ec2 release-address --allocation-id "$ONPREM_NAT_EIP_ALLOC" --region "${AWS_REGION}"
fi

# 9. Wait for all instances to terminate
ALL_IDS=("${TERM_IDS[@]}" "${BIZ_IDS[@]}" "${CGW_INST_IDS[@]}")
if [[ ${#ALL_IDS[@]} -gt 0 ]]; then
    log_info "Waiting for all instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids "${ALL_IDS[@]}" --region "${AWS_REGION}" 2>/dev/null || true
    log_info "All instances terminated"
fi

# 10. Delete security groups
for SG_VAR in CGW_SG_ID TRAFFIC_GEN_SG_ID BIZ_HOST_SG_ID; do
    SG_ID="${!SG_VAR:-}"
    if [[ -n "$SG_ID" ]]; then
        cleanup_step "Security group $SG_VAR ($SG_ID)" \
            aws ec2 delete-security-group --group-id "$SG_ID" --region "${AWS_REGION}"
    fi
done

# 11. Delete subnets
for SUBNET_VAR in ONPREM_PUBLIC_SUBNET_ID ONPREM_PRIVATE_SUBNET_ID; do
    SUBNET_ID="${!SUBNET_VAR:-}"
    if [[ -n "$SUBNET_ID" ]]; then
        cleanup_step "Subnet $SUBNET_VAR ($SUBNET_ID)" \
            aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "${AWS_REGION}"
    fi
done

# 12. Delete route tables
for RTB_VAR in ONPREM_PUBLIC_RTB_ID ONPREM_PRIVATE_RTB_ID; do
    RTB_ID="${!RTB_VAR:-}"
    if [[ -n "$RTB_ID" ]]; then
        # Disassociate non-main associations first
        ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids "$RTB_ID" \
            --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" \
            --output text --region "${AWS_REGION}" 2>/dev/null || echo "")
        for ASSOC_ID in $ASSOC_IDS; do
            [[ "$ASSOC_ID" == "None" ]] && continue
            cleanup_step "Route table association $ASSOC_ID" \
                aws ec2 disassociate-route-table --association-id "$ASSOC_ID" --region "${AWS_REGION}"
        done
        cleanup_step "Route table $RTB_VAR ($RTB_ID)" \
            aws ec2 delete-route-table --route-table-id "$RTB_ID" --region "${AWS_REGION}"
    fi
done

# 13. Detach and delete Internet Gateway
if [[ -n "${ONPREM_IGW_ID:-}" ]]; then
    if [[ -n "${ONPREM_VPC_ID:-}" ]]; then
        cleanup_step "Detach IGW $ONPREM_IGW_ID from VPC $ONPREM_VPC_ID" \
            aws ec2 detach-internet-gateway --internet-gateway-id "$ONPREM_IGW_ID" \
                --vpc-id "$ONPREM_VPC_ID" --region "${AWS_REGION}"
    fi
    cleanup_step "Internet gateway $ONPREM_IGW_ID" \
        aws ec2 delete-internet-gateway --internet-gateway-id "$ONPREM_IGW_ID" --region "${AWS_REGION}"
fi

# 14. Delete VPC
if [[ -n "${ONPREM_VPC_ID:-}" ]]; then
    cleanup_step "VPC $ONPREM_VPC_ID" \
        aws ec2 delete-vpc --vpc-id "$ONPREM_VPC_ID" --region "${AWS_REGION}"
fi

# 15. Remove test-env-vars.sh
if [[ -f "$TEST_ENV_FILE" ]]; then
    cleanup_step "test-env-vars.sh" rm -f "$TEST_ENV_FILE"
fi

log_info "Test cleanup complete"
