#!/usr/bin/env bash
# ENI lifecycle manager - keeps mirror sessions in sync with appliance ENIs.
# Designed to run as a cron job.
#
# Install: */2 * * * * /path/to/10-eni-lifecycle.sh >> /var/log/dx-eni-lifecycle.log 2>&1
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

require_vars PROJECT_TAG MIRROR_TARGET_ID MIRROR_FILTER_ID MIRROR_VNI

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log_lifecycle() {
    echo "[$TIMESTAMP] $1"
}

# Discover current appliance ENIs by project tag
CURRENT_ENIS=$(aws ec2 describe-network-interfaces \
    --filters \
        "Name=tag:Project,Values=$PROJECT_TAG" \
        "Name=status,Values=in-use" \
        "Name=attachment.instance-owner-id,Values=$(aws sts get-caller-identity --query Account --output text)" \
    --query 'NetworkInterfaces[?Attachment.DeviceIndex==`0`].NetworkInterfaceId' \
    --output text 2>/dev/null || echo "")

# Filter to only ENIs attached to appliance instances
APPLIANCE_IDS=()
while IFS='=' read -r key value; do
    if [[ "$key" =~ ^APPLIANCE_INSTANCE_ID_ ]]; then
        APPLIANCE_IDS+=("$value")
    fi
done < <(env | grep "^APPLIANCE_INSTANCE_ID_" || true)

APPLIANCE_ENIS=()
if [[ ${#APPLIANCE_IDS[@]} -gt 0 ]]; then
    ENIS_RAW=$(aws ec2 describe-network-interfaces \
        --filters "Name=attachment.instance-id,Values=$(IFS=,; echo "${APPLIANCE_IDS[*]}")" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || echo "")
    for ENI in $ENIS_RAW; do
        APPLIANCE_ENIS+=("$ENI")
    done
fi

log_lifecycle "Current appliance ENIs: ${APPLIANCE_ENIS[*]:-none}"

# Get existing mirror session source ENIs
EXISTING_SESSIONS=()
EXISTING_SESSION_MAP=() # "session_id:eni_id" pairs
if [[ -n "${MIRROR_SESSION_IDS:-}" ]]; then
    IFS=',' read -ra SESSION_LIST <<< "$MIRROR_SESSION_IDS"
    for SID in "${SESSION_LIST[@]}"; do
        SRC_ENI=$(aws ec2 describe-traffic-mirror-sessions \
            --traffic-mirror-session-ids "$SID" \
            --query 'TrafficMirrorSessions[0].NetworkInterfaceId' --output text 2>/dev/null || echo "")
        if [[ -n "$SRC_ENI" && "$SRC_ENI" != "None" ]]; then
            EXISTING_SESSIONS+=("$SRC_ENI")
            EXISTING_SESSION_MAP+=("${SID}:${SRC_ENI}")
        fi
    done
fi

log_lifecycle "Existing mirror session ENIs: ${EXISTING_SESSIONS[*]:-none}"

CHANGED=false
NEW_SESSION_IDS=()

# Keep existing sessions for ENIs that are still present
for ENTRY in "${EXISTING_SESSION_MAP[@]:-}"; do
    [[ -z "$ENTRY" ]] && continue
    SID="${ENTRY%%:*}"
    ENI="${ENTRY##*:}"
    FOUND=false
    for A_ENI in "${APPLIANCE_ENIS[@]:-}"; do
        if [[ "$ENI" == "$A_ENI" ]]; then
            FOUND=true
            break
        fi
    done
    if [[ "$FOUND" == "true" ]]; then
        NEW_SESSION_IDS+=("$SID")
    else
        # Stale: ENI no longer in appliance list, delete session
        log_lifecycle "STALE: Deleting mirror session $SID (ENI $ENI no longer exists)"
        aws ec2 delete-traffic-mirror-session --traffic-mirror-session-id "$SID" 2>/dev/null || true
        CHANGED=true
    fi
done

# Find new ENIs that don't have sessions
NEXT_SESSION_NUM=${#NEW_SESSION_IDS[@]}
for A_ENI in "${APPLIANCE_ENIS[@]:-}"; do
    [[ -z "$A_ENI" ]] && continue
    HAS_SESSION=false
    for E_ENI in "${EXISTING_SESSIONS[@]:-}"; do
        if [[ "$A_ENI" == "$E_ENI" ]]; then
            HAS_SESSION=true
            break
        fi
    done
    if [[ "$HAS_SESSION" == "false" ]]; then
        NEXT_SESSION_NUM=$((NEXT_SESSION_NUM + 1))
        log_lifecycle "NEW: Creating mirror session for ENI $A_ENI"
        NEW_SID=$(aws ec2 create-traffic-mirror-session \
            --network-interface-id "$A_ENI" \
            --traffic-mirror-target-id "$MIRROR_TARGET_ID" \
            --traffic-mirror-filter-id "$MIRROR_FILTER_ID" \
            --session-number "$NEXT_SESSION_NUM" \
            --virtual-network-id "$MIRROR_VNI" \
            --description "Auto-created by eni-lifecycle for $A_ENI" \
            --tag-specifications "ResourceType=traffic-mirror-session,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
            --query 'TrafficMirrorSession.TrafficMirrorSessionId' --output text 2>/dev/null || echo "")
        if [[ -n "$NEW_SID" && "$NEW_SID" != "None" ]]; then
            NEW_SESSION_IDS+=("$NEW_SID")
            log_lifecycle "Created mirror session $NEW_SID for ENI $A_ENI"
            CHANGED=true
        else
            log_lifecycle "ERROR: Failed to create mirror session for ENI $A_ENI"
        fi
    fi
done

# Update env-vars if changed
if [[ "$CHANGED" == "true" ]]; then
    UPDATED_IDS=$(IFS=,; echo "${NEW_SESSION_IDS[*]}")
    save_var MIRROR_SESSION_IDS "$UPDATED_IDS"
    log_lifecycle "Updated MIRROR_SESSION_IDS=$UPDATED_IDS"
else
    log_lifecycle "No changes needed"
fi
