#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

require_vars MIRROR_TARGET_ID MIRROR_FILTER_ID MIRROR_VNI PROJECT_TAG

# --- Wait for Appliance instances to be ready ---
IDX=0
while true; do
    VAR_NAME="APPLIANCE_INSTANCE_ID_${IDX}"
    if [[ -n "${!VAR_NAME:-}" ]]; then
        log_info "Waiting for appliance ${!VAR_NAME} status checks..."
        aws ec2 wait instance-status-ok --instance-ids "${!VAR_NAME}" 2>/dev/null || true
        IDX=$((IDX + 1))
    else
        break
    fi
done

# --- Discover Appliance ENIs ---
log_info "Discovering appliance ENIs..."
ENIS=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=${PROJECT_TAG}" \
    "Name=tag:Name,Values=dx-appliance-*" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].NetworkInterfaces[0].NetworkInterfaceId' \
  --output text)

if [[ -z "$ENIS" ]]; then
  log_error "No appliance ENIs found"
  exit 1
fi

log_info "Found appliance ENIs: $ENIS"

# --- Create mirror sessions ---
SESSION_IDS=()

for ENI in $ENIS; do
  log_info "Processing ENI: $ENI"

  # Check if session already exists for this ENI
  EXISTING=$(aws ec2 describe-traffic-mirror-sessions \
    --filters "Name=traffic-mirror-target-id,Values=${MIRROR_TARGET_ID}" \
    --query "TrafficMirrorSessions[?NetworkInterfaceId=='${ENI}'].TrafficMirrorSessionId" \
    --output text)

  if [[ -n "$EXISTING" ]]; then
    log_info "Mirror session already exists for $ENI: $EXISTING"
    SESSION_IDS+=("$EXISTING")
  else
    # Find first available session number for this ENI
    USED_NUMS=$(aws ec2 describe-traffic-mirror-sessions \
      --filters "Name=network-interface-id,Values=${ENI}" \
      --query 'TrafficMirrorSessions[].SessionNumber' --output text 2>/dev/null || true)
    SESSION_NUM=1
    while echo "$USED_NUMS" | grep -qw "$SESSION_NUM" 2>/dev/null; do
      SESSION_NUM=$((SESSION_NUM + 1))
    done

    log_info "Creating mirror session for $ENI (session-number=$SESSION_NUM)"
    SESSION_ID=$(aws ec2 create-traffic-mirror-session \
      --network-interface-id "$ENI" \
      --traffic-mirror-target-id "$MIRROR_TARGET_ID" \
      --traffic-mirror-filter-id "$MIRROR_FILTER_ID" \
      --session-number "$SESSION_NUM" \
      --virtual-network-id "$MIRROR_VNI" \
      --packet-length 128 \
      --tag-specifications "ResourceType=traffic-mirror-session,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" \
      --query 'TrafficMirrorSession.TrafficMirrorSessionId' --output text)

    log_info "Created mirror session: $SESSION_ID"
    SESSION_IDS+=("$SESSION_ID")
  fi
done

# Save comma-separated list of session IDs
IFS=','
save_var MIRROR_SESSION_IDS "${SESSION_IDS[*]}"
unset IFS

log_info "Mirror sessions setup complete: ${SESSION_IDS[*]}"
