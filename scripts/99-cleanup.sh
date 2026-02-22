#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

# Reverse-order cleanup of all dx-monitoring resources

FORCE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
fi

if [[ "$FORCE" != "true" ]]; then
    echo "This will delete ALL dx-monitoring resources. Type 'yes' to confirm:"
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

# 1. Mirror Sessions
if [[ -n "${MIRROR_SESSION_IDS:-}" ]]; then
    IFS=',' read -ra SESSIONS <<< "$MIRROR_SESSION_IDS"
    for SID in "${SESSIONS[@]}"; do
        cleanup_step "Mirror session $SID" \
            aws ec2 delete-traffic-mirror-session --traffic-mirror-session-id "$SID"
    done
fi

# 2. Mirror Filter
if [[ -n "${MIRROR_FILTER_ID:-}" ]]; then
    cleanup_step "Mirror filter $MIRROR_FILTER_ID" \
        aws ec2 delete-traffic-mirror-filter --traffic-mirror-filter-id "$MIRROR_FILTER_ID"
fi

# 3. Mirror Target
if [[ -n "${MIRROR_TARGET_ID:-}" ]]; then
    cleanup_step "Mirror target $MIRROR_TARGET_ID" \
        aws ec2 delete-traffic-mirror-target --traffic-mirror-target-id "$MIRROR_TARGET_ID"
fi

# 4. NLB: listener, target group, load balancer
if [[ -n "${NLB_ARN:-}" ]]; then
    # Delete listeners
    LISTENER_ARNS=$(aws elbv2 describe-listeners --load-balancer-arn "$NLB_ARN" \
        --query 'Listeners[].ListenerArn' --output text 2>/dev/null || echo "")
    for LARN in $LISTENER_ARNS; do
        cleanup_step "NLB listener $LARN" \
            aws elbv2 delete-listener --listener-arn "$LARN"
    done

    # Delete load balancer first (then TG after)
    cleanup_step "NLB $NLB_ARN" \
        aws elbv2 delete-load-balancer --load-balancer-arn "$NLB_ARN"
fi

if [[ -n "${MIRROR_TG_ARN:-}" ]]; then
    # Wait briefly for NLB deletion to propagate
    if [[ -n "${NLB_ARN:-}" ]]; then
        log_info "Waiting for NLB deletion to propagate..."
        sleep 10
    fi
    cleanup_step "NLB target group $MIRROR_TG_ARN" \
        aws elbv2 delete-target-group --target-group-arn "$MIRROR_TG_ARN"
fi

# 5. Probe instances
PROBE_IDS=()
while IFS='=' read -r key value; do
    if [[ "$key" =~ ^PROBE_INSTANCE_ID_ ]]; then
        PROBE_IDS+=("$value")
    fi
done < <(env | grep "^PROBE_INSTANCE_ID_" || true)

if [[ ${#PROBE_IDS[@]} -gt 0 ]]; then
    cleanup_step "Probe instances (${PROBE_IDS[*]})" \
        aws ec2 terminate-instances --instance-ids "${PROBE_IDS[@]}"
fi

# 6. VGW Ingress route table
if [[ -n "${VGW_INGRESS_RTB_ID:-}" ]]; then
    # Disassociate
    if [[ -n "${VGW_INGRESS_ASSOC_ID:-}" ]]; then
        cleanup_step "VGW ingress route table disassociation $VGW_INGRESS_ASSOC_ID" \
            aws ec2 disassociate-route-table --association-id "$VGW_INGRESS_ASSOC_ID"
    fi

    # Delete routes (non-local)
    ROUTES=$(aws ec2 describe-route-tables --route-table-ids "$VGW_INGRESS_RTB_ID" \
        --query "RouteTables[0].Routes[?GatewayId!='local'].DestinationCidrBlock" --output text 2>/dev/null || echo "")
    for CIDR in $ROUTES; do
        [[ "$CIDR" == "None" ]] && continue
        cleanup_step "Route $CIDR in $VGW_INGRESS_RTB_ID" \
            aws ec2 delete-route --route-table-id "$VGW_INGRESS_RTB_ID" --destination-cidr-block "$CIDR"
    done

    cleanup_step "VGW ingress route table $VGW_INGRESS_RTB_ID" \
        aws ec2 delete-route-table --route-table-id "$VGW_INGRESS_RTB_ID"
fi

# 7. GWLBEs
while IFS='=' read -r key value; do
    if [[ "$key" =~ ^GWLBE_ID_ ]]; then
        cleanup_step "GWLBE $value" \
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$value"
    fi
done < <(env | grep "^GWLBE_ID_" || true)

# 8. Endpoint Service
if [[ -n "${ENDPOINT_SERVICE_ID:-}" ]]; then
    cleanup_step "Endpoint service $ENDPOINT_SERVICE_ID" \
        aws ec2 delete-vpc-endpoint-service-configurations --service-ids "$ENDPOINT_SERVICE_ID"
fi

# 9. GWLB: listener, target group, load balancer
if [[ -n "${GWLB_ARN:-}" ]]; then
    GWLB_LISTENER_ARNS=$(aws elbv2 describe-listeners --load-balancer-arn "$GWLB_ARN" \
        --query 'Listeners[].ListenerArn' --output text 2>/dev/null || echo "")
    for LARN in $GWLB_LISTENER_ARNS; do
        cleanup_step "GWLB listener $LARN" \
            aws elbv2 delete-listener --listener-arn "$LARN"
    done

    cleanup_step "GWLB $GWLB_ARN" \
        aws elbv2 delete-load-balancer --load-balancer-arn "$GWLB_ARN"
fi

if [[ -n "${GWLB_TG_ARN:-}" ]]; then
    if [[ -n "${GWLB_ARN:-}" ]]; then
        log_info "Waiting for GWLB deletion to propagate..."
        sleep 10
    fi
    cleanup_step "GWLB target group $GWLB_TG_ARN" \
        aws elbv2 delete-target-group --target-group-arn "$GWLB_TG_ARN"
fi

# 10. Appliance instances
APPLIANCE_IDS=()
while IFS='=' read -r key value; do
    if [[ "$key" =~ ^APPLIANCE_INSTANCE_ID_ ]]; then
        APPLIANCE_IDS+=("$value")
    fi
done < <(env | grep "^APPLIANCE_INSTANCE_ID_" || true)

if [[ ${#APPLIANCE_IDS[@]} -gt 0 ]]; then
    cleanup_step "Appliance instances (${APPLIANCE_IDS[*]})" \
        aws ec2 terminate-instances --instance-ids "${APPLIANCE_IDS[@]}"
fi

# 11. Wait for all instances to terminate
ALL_IDS=("${PROBE_IDS[@]}" "${APPLIANCE_IDS[@]}")
if [[ ${#ALL_IDS[@]} -gt 0 ]]; then
    log_info "Waiting for all instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids "${ALL_IDS[@]}" 2>/dev/null || true
    log_info "All instances terminated"
fi

# 12. Security Groups
for SG_VAR in APPLIANCE_SG_ID PROBE_SG_ID; do
    SG_ID="${!SG_VAR:-}"
    if [[ -n "$SG_ID" ]]; then
        cleanup_step "Security group $SG_VAR ($SG_ID)" \
            aws ec2 delete-security-group --group-id "$SG_ID"
    fi
done

# 13. IAM Role + Instance Profile
if [[ -n "${PROBE_IAM_ROLE_NAME:-}" ]]; then
    cleanup_step "Remove role from instance profile" \
        aws iam remove-role-from-instance-profile \
            --instance-profile-name "$PROBE_IAM_ROLE_NAME" \
            --role-name "$PROBE_IAM_ROLE_NAME"
    cleanup_step "Delete instance profile $PROBE_IAM_ROLE_NAME" \
        aws iam delete-instance-profile \
            --instance-profile-name "$PROBE_IAM_ROLE_NAME"
    cleanup_step "Delete inline policy on $PROBE_IAM_ROLE_NAME" \
        aws iam delete-role-policy \
            --role-name "$PROBE_IAM_ROLE_NAME" \
            --policy-name "dx-probe-policy"
    cleanup_step "Delete IAM role $PROBE_IAM_ROLE_NAME" \
        aws iam delete-role --role-name "$PROBE_IAM_ROLE_NAME"
fi

# 14. Remove env-vars.sh
ENV_FILE="$PROJECT_DIR/env-vars.sh"
if [[ -f "$ENV_FILE" ]]; then
    cleanup_step "env-vars.sh" rm -f "$ENV_FILE"
fi

log_info "Cleanup complete"
