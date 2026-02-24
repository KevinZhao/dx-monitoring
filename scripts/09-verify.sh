#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

DEPLOY_MODE="${DEPLOY_MODE:-gwlb}"

# 5-stage verification with color-coded PASS/FAIL

PASS=0
FAIL=0
TOTAL=0

check_pass() {
    local desc="$1"
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  \033[32m[PASS]\033[0m $desc"
}

check_fail() {
    local desc="$1"
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  \033[31m[FAIL]\033[0m $desc"
}

stage_header() {
    echo ""
    echo -e "\033[1;36m=== Stage $1: $2 ===\033[0m"
}

# ========== Stage 1: Infrastructure Status ==========
stage_header 1 "Infrastructure Status"

# Security groups
SG_LIST=("PROBE_SG_ID")
[[ "$DEPLOY_MODE" == "gwlb" ]] && SG_LIST=("APPLIANCE_SG_ID" "PROBE_SG_ID")

for SG_VAR in "${SG_LIST[@]}"; do
    SG_ID="${!SG_VAR:-}"
    if [[ -n "$SG_ID" ]]; then
        SG_STATE=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "NOTFOUND")
        if [[ "$SG_STATE" != "NOTFOUND" ]]; then
            check_pass "Security group $SG_VAR ($SG_ID) exists"
        else
            check_fail "Security group $SG_VAR ($SG_ID) not found"
        fi
    else
        check_fail "Security group $SG_VAR not set"
    fi
done

# Appliance instances (gwlb mode only)
if [[ "$DEPLOY_MODE" == "gwlb" ]]; then
    while IFS='=' read -r key value; do
        if [[ "$key" =~ ^APPLIANCE_INSTANCE_ID_ ]]; then
            STATE=$(aws ec2 describe-instances --instance-ids "$value" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")
            if [[ "$STATE" == "running" ]]; then
                check_pass "Appliance instance $value is running"
            else
                check_fail "Appliance instance $value state=$STATE"
            fi
        fi
    done < <(env | grep "^APPLIANCE_INSTANCE_ID_" || true)
fi

# Probe instances
while IFS='=' read -r key value; do
    if [[ "$key" =~ ^PROBE_INSTANCE_ID_ ]]; then
        STATE=$(aws ec2 describe-instances --instance-ids "$value" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")
        if [[ "$STATE" == "running" ]]; then
            check_pass "Probe instance $value is running"
        else
            check_fail "Probe instance $value state=$STATE"
        fi
    fi
done < <(env | grep "^PROBE_INSTANCE_ID_" || true)

# GWLB + GWLBEs (gwlb mode only)
if [[ "$DEPLOY_MODE" == "gwlb" ]]; then
    if [[ -n "${GWLB_ARN:-}" ]]; then
        GWLB_STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$GWLB_ARN" --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "unknown")
        if [[ "$GWLB_STATE" == "active" ]]; then
            check_pass "GWLB state=active"
        else
            check_fail "GWLB state=$GWLB_STATE"
        fi
    else
        check_fail "GWLB_ARN not set"
    fi

    while IFS='=' read -r key value; do
        if [[ "$key" =~ ^GWLBE_ID_ ]]; then
            GWLBE_STATE=$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$value" --query 'VpcEndpoints[0].State' --output text 2>/dev/null || echo "unknown")
            if [[ "$GWLBE_STATE" == "available" ]]; then
                check_pass "GWLBE $value state=available"
            else
                check_fail "GWLBE $value state=$GWLBE_STATE"
            fi
        fi
    done < <(env | grep "^GWLBE_ID_" || true)
fi

# ========== Stage 2: Route Tables ==========
stage_header 2 "Route Tables"

if [[ "$DEPLOY_MODE" == "gwlb" ]]; then
    if [[ -n "${VGW_INGRESS_RTB_ID:-}" ]]; then
        RTB_EXISTS=$(aws ec2 describe-route-tables --route-table-ids "$VGW_INGRESS_RTB_ID" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "NOTFOUND")
        if [[ "$RTB_EXISTS" != "NOTFOUND" ]]; then
            check_pass "VGW Ingress route table $VGW_INGRESS_RTB_ID exists"
        else
            check_fail "VGW Ingress route table $VGW_INGRESS_RTB_ID not found"
        fi

        EDGE_ASSOC=$(aws ec2 describe-route-tables --route-table-ids "$VGW_INGRESS_RTB_ID" \
            --query "RouteTables[0].Associations[?GatewayId=='${VGW_ID}'].RouteTableAssociationId" --output text 2>/dev/null || echo "")
        if [[ -n "$EDGE_ASSOC" && "$EDGE_ASSOC" != "None" ]]; then
            check_pass "Edge association points to VGW ($VGW_ID)"
        else
            check_fail "Edge association to VGW not found"
        fi

        IFS=',' read -ra CIDRS <<< "$BUSINESS_SUBNET_CIDRS"
        for CIDR in "${CIDRS[@]}"; do
            ROUTE_TARGET=$(aws ec2 describe-route-tables --route-table-ids "$VGW_INGRESS_RTB_ID" \
                --query "RouteTables[0].Routes[?DestinationCidrBlock=='${CIDR}'].VpcEndpointId" --output text 2>/dev/null || echo "")
            if [[ -n "$ROUTE_TARGET" && "$ROUTE_TARGET" != "None" ]]; then
                check_pass "Route $CIDR -> GWLBE ($ROUTE_TARGET)"
            else
                check_fail "Route $CIDR -> GWLBE not found"
            fi
        done
    else
        check_fail "VGW_INGRESS_RTB_ID not set"
    fi
else
    check_pass "Route tables: direct mode uses normal VPC routing (no GWLB interception)"
fi

# ========== Stage 3: Mirror Configuration ==========
stage_header 3 "Mirror Configuration"

if [[ "$DEPLOY_MODE" == "gwlb" ]]; then
    # gwlb mode: count appliance ENIs vs mirror sessions
    APPLIANCE_IDS=()
    while IFS='=' read -r key value; do
        if [[ "$key" =~ ^APPLIANCE_INSTANCE_ID_ ]]; then
            APPLIANCE_IDS+=("$value")
        fi
    done < <(env | grep "^APPLIANCE_INSTANCE_ID_" || true)

    ENI_COUNT=0
    if [[ ${#APPLIANCE_IDS[@]} -gt 0 ]]; then
        ENI_COUNT=$(aws ec2 describe-network-interfaces \
            --filters "Name=attachment.instance-id,Values=$(IFS=,; echo "${APPLIANCE_IDS[*]}")" \
            --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo "0")
    fi

    SESSION_COUNT=0
    if [[ -n "${MIRROR_SESSION_IDS:-}" ]]; then
        IFS=',' read -ra SESSIONS <<< "$MIRROR_SESSION_IDS"
        SESSION_COUNT=${#SESSIONS[@]}
    fi

    if [[ "$ENI_COUNT" -gt 0 && "$ENI_COUNT" == "$SESSION_COUNT" ]]; then
        check_pass "Appliance ENI count ($ENI_COUNT) matches mirror session count ($SESSION_COUNT)"
    else
        check_fail "Appliance ENI count ($ENI_COUNT) vs mirror session count ($SESSION_COUNT)"
    fi
else
    # direct mode: count business ENI mirror sessions
    SESSION_COUNT=$(aws ec2 describe-traffic-mirror-sessions \
        --filters "Name=traffic-mirror-target-id,Values=${MIRROR_TARGET_ID:-none}" \
        --query 'length(TrafficMirrorSessions)' --output text 2>/dev/null || echo "0")
    if [[ "$SESSION_COUNT" -gt 0 ]]; then
        check_pass "Business ENI mirror sessions active: $SESSION_COUNT"
    else
        check_fail "No mirror sessions found (run 11-business-mirror-sync.sh or 12-deploy-mirror-lambda.sh)"
    fi
fi

# Mirror filter rules
if [[ -n "${MIRROR_FILTER_ID:-}" ]]; then
    RULE_COUNT=$(aws ec2 describe-traffic-mirror-filter-rules \
        --filters "Name=traffic-mirror-filter-id,Values=$MIRROR_FILTER_ID" \
        --query 'length(TrafficMirrorFilterRules)' --output text 2>/dev/null || echo "0")
    if [[ "$RULE_COUNT" -gt 0 ]]; then
        check_pass "Mirror filter $MIRROR_FILTER_ID has $RULE_COUNT rule(s)"
    else
        check_fail "Mirror filter $MIRROR_FILTER_ID has no rules"
    fi
else
    check_fail "MIRROR_FILTER_ID not set"
fi

# ========== Stage 4: Probe Health ==========
stage_header 4 "Probe Health"

# NLB target health (gwlb mode only — direct mode has no NLB)
if [[ "$DEPLOY_MODE" == "gwlb" ]]; then
    if [[ -n "${NLB_ARN:-}" && -n "${MIRROR_TG_ARN:-}" ]]; then
        UNHEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$MIRROR_TG_ARN" \
            --query "TargetHealthDescriptions[?TargetHealth.State!='healthy']" --output text 2>/dev/null || echo "")
        HEALTHY_COUNT=$(aws elbv2 describe-target-health --target-group-arn "$MIRROR_TG_ARN" \
            --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text 2>/dev/null || echo "0")
        if [[ -z "$UNHEALTHY" || "$UNHEALTHY" == "None" ]]; then
            check_pass "NLB targets all healthy ($HEALTHY_COUNT target(s))"
        else
            check_fail "NLB has unhealthy targets"
        fi
    else
        check_fail "NLB_ARN or MIRROR_TG_ARN not set"
    fi
fi

# SSH probe service check
KEY_FILE="$PROJECT_DIR/${KEY_PAIR_NAME}.pem"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i $KEY_FILE"

while IFS='=' read -r key value; do
    if [[ "$key" =~ ^PROBE_PRIVATE_IP_ ]]; then
        STATUS=$(ssh $SSH_OPTS "ec2-user@${value}" "sudo systemctl is-active dx-probe" 2>/dev/null || echo "inactive")
        if [[ "$STATUS" == "active" ]]; then
            check_pass "dx-probe active on $value"
        else
            check_fail "dx-probe $STATUS on $value"
        fi
    fi
done < <(env | grep "^PROBE_PRIVATE_IP_" || true)

# ========== Stage 5: End-to-End ==========
stage_header 5 "End-to-End"

while IFS='=' read -r key value; do
    if [[ "$key" =~ ^PROBE_PRIVATE_IP_ ]]; then
        log_info "Checking VXLAN traffic on $value (30s timeout)..."
        CAPTURE=$(ssh $SSH_OPTS "ec2-user@${value}" \
            "sudo timeout 30 tcpdump -c 5 -i any udp port 4789 2>&1" 2>/dev/null || echo "")
        if echo "$CAPTURE" | grep -q "packets captured"; then
            PKT_COUNT=$(echo "$CAPTURE" | grep "packets captured" | awk '{print $1}')
            if [[ "$PKT_COUNT" -gt 0 ]]; then
                check_pass "VXLAN packets captured on $value ($PKT_COUNT packets)"
            else
                check_fail "No VXLAN packets captured on $value"
            fi
        else
            check_fail "tcpdump failed or no packets on $value"
        fi
    fi
done < <(env | grep "^PROBE_PRIVATE_IP_" || true)

# ========== Summary ==========
echo ""
echo -e "\033[1m=== Summary ===\033[0m"
echo -e "  Total checks: $TOTAL"
echo -e "  \033[32mPassed: $PASS\033[0m"
echo -e "  \033[31mFailed: $FAIL\033[0m"
echo ""

if [[ $FAIL -gt 0 ]]; then
    log_warn "$PASS/$TOTAL checks passed ($FAIL failed)"
    exit 1
else
    log_info "$PASS/$TOTAL checks passed"
fi
