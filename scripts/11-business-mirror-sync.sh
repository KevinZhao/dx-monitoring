#!/usr/bin/env bash
# Business ENI mirror sync — keeps mirror sessions in sync with business instances.
# For B2 architecture: mirror directly on business ENIs, no GWLB/Appliance needed.
#
# Discovers all running EC2 instances in BUSINESS_SUBNET_CIDRS,
# creates mirror sessions for new ENIs, deletes sessions for terminated ones.
#
# Usage:
#   One-time:  bash scripts/11-business-mirror-sync.sh
#   Cron:      */2 * * * * /path/to/11-business-mirror-sync.sh >> /var/log/dx-mirror-sync.log 2>&1
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

DEPLOY_MODE="${DEPLOY_MODE:-gwlb}"
if [[ "$DEPLOY_MODE" != "direct" ]]; then
    log_warn "DEPLOY_MODE=$DEPLOY_MODE — business ENI mirror sync is for 'direct' mode only. Skipping."
    exit 0
fi

require_vars VPC_ID PROJECT_TAG MIRROR_TARGET_ID MIRROR_FILTER_ID MIRROR_VNI BUSINESS_SUBNET_CIDRS

MIRROR_TAG="dx-mirror-auto"  # tag to identify auto-managed sessions

# ================================================================
# Step 1: Discover business subnet IDs from CIDRs
# ================================================================
BUSINESS_SUBNET_IDS=()
IFS=',' read -ra CIDRS <<< "$BUSINESS_SUBNET_CIDRS"
for CIDR in "${CIDRS[@]}"; do
    SID=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$CIDR" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "None")
    if [[ -n "$SID" && "$SID" != "None" ]]; then
        BUSINESS_SUBNET_IDS+=("$SID")
    else
        log_warn "No subnet found for CIDR $CIDR"
    fi
done

if [[ ${#BUSINESS_SUBNET_IDS[@]} -eq 0 ]]; then
    log_error "No business subnets found"
    exit 1
fi
log_info "Business subnets: ${BUSINESS_SUBNET_IDS[*]}"

# ================================================================
# Step 2: Discover all running instances in business subnets
# ================================================================
DESIRED_ENIS=()
for SUBNET_ID in "${BUSINESS_SUBNET_IDS[@]}"; do
    ENIS=$(aws ec2 describe-instances \
        --filters \
            "Name=subnet-id,Values=$SUBNET_ID" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].NetworkInterfaces[0].NetworkInterfaceId' \
        --output text 2>/dev/null || echo "")
    for ENI in $ENIS; do
        [[ "$ENI" == "None" || -z "$ENI" ]] && continue
        DESIRED_ENIS+=("$ENI")
    done
done

log_info "Desired mirror ENIs (${#DESIRED_ENIS[@]}): ${DESIRED_ENIS[*]:-none}"

# ================================================================
# Step 3: Get existing auto-managed mirror sessions
# ================================================================
declare -A EXISTING_MAP  # eni -> session_id
EXISTING_SIDS=()

SESSIONS_JSON=$(aws ec2 describe-traffic-mirror-sessions \
    --filters "Name=traffic-mirror-target-id,Values=$MIRROR_TARGET_ID" \
    --query 'TrafficMirrorSessions[].{SID:TrafficMirrorSessionId,ENI:NetworkInterfaceId}' \
    --output json 2>/dev/null || echo "[]")

while IFS= read -r line; do
    SID=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['SID'])" 2>/dev/null || echo "")
    ENI=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['ENI'])" 2>/dev/null || echo "")
    if [[ -n "$SID" && -n "$ENI" && "$SID" != "None" ]]; then
        EXISTING_MAP["$ENI"]="$SID"
        EXISTING_SIDS+=("$SID")
    fi
done < <(echo "$SESSIONS_JSON" | python3 -c "import sys,json; [print(json.dumps(x)) for x in json.load(sys.stdin)]" 2>/dev/null)

log_info "Existing mirror sessions (${#EXISTING_SIDS[@]})"

# ================================================================
# Step 4: Diff — create new, delete stale
# ================================================================
CREATED=0
DELETED=0
UNCHANGED=0

# Create sessions for new ENIs
for ENI in "${DESIRED_ENIS[@]}"; do
    if [[ -n "${EXISTING_MAP[$ENI]:-}" ]]; then
        UNCHANGED=$((UNCHANGED + 1))
        continue
    fi

    # Find available session number for this ENI
    USED_NUMS=$(aws ec2 describe-traffic-mirror-sessions \
        --filters "Name=network-interface-id,Values=$ENI" \
        --query 'TrafficMirrorSessions[].SessionNumber' --output text 2>/dev/null || echo "")
    SESSION_NUM=1
    while echo "$USED_NUMS" | grep -qw "$SESSION_NUM" 2>/dev/null; do
        SESSION_NUM=$((SESSION_NUM + 1))
    done

    SID=$(aws ec2 create-traffic-mirror-session \
        --network-interface-id "$ENI" \
        --traffic-mirror-target-id "$MIRROR_TARGET_ID" \
        --traffic-mirror-filter-id "$MIRROR_FILTER_ID" \
        --session-number "$SESSION_NUM" \
        --virtual-network-id "$MIRROR_VNI" \
        --packet-length 128 \
        --tag-specifications "ResourceType=traffic-mirror-session,Tags=[{Key=Project,Value=$PROJECT_TAG},{Key=ManagedBy,Value=$MIRROR_TAG}]" \
        --query 'TrafficMirrorSession.TrafficMirrorSessionId' --output text 2>/dev/null || echo "FAILED")

    if [[ "$SID" != "FAILED" && -n "$SID" ]]; then
        log_info "CREATED mirror session $SID for ENI $ENI"
        CREATED=$((CREATED + 1))
    else
        log_error "FAILED to create mirror session for ENI $ENI"
    fi
done

# Delete sessions for ENIs no longer in desired set
declare -A DESIRED_SET
for ENI in "${DESIRED_ENIS[@]}"; do DESIRED_SET["$ENI"]=1; done

for ENI in "${!EXISTING_MAP[@]}"; do
    if [[ -z "${DESIRED_SET[$ENI]:-}" ]]; then
        SID="${EXISTING_MAP[$ENI]}"
        aws ec2 delete-traffic-mirror-session --traffic-mirror-session-id "$SID" 2>/dev/null || true
        log_info "DELETED stale mirror session $SID (ENI $ENI terminated)"
        DELETED=$((DELETED + 1))
    fi
done

log_info "Sync complete: created=$CREATED deleted=$DELETED unchanged=$UNCHANGED total=${#DESIRED_ENIS[@]}"
