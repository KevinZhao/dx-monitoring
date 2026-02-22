#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

require_vars ONPREM_CIDRS

# --- Create Mirror Filter ---
if check_var_exists MIRROR_FILTER_ID; then
  log_info "Mirror filter already exists, skipping creation"
else
  log_info "Creating traffic mirror filter..."
  MIRROR_FILTER_ID=$(aws ec2 create-traffic-mirror-filter \
    --description "DX monitoring filter" \
    --tag-specifications "ResourceType=traffic-mirror-filter,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'TrafficMirrorFilter.TrafficMirrorFilterId' --output text)

  save_var MIRROR_FILTER_ID "$MIRROR_FILTER_ID"
  log_info "Created mirror filter: $MIRROR_FILTER_ID"
fi

load_env

# --- Create ACCEPT rules for each on-prem CIDR ---
IFS=',' read -ra CIDRS <<< "$ONPREM_CIDRS"
RULE_NUM=1

for CIDR in "${CIDRS[@]}"; do
  CIDR=$(echo "$CIDR" | xargs)  # trim whitespace
  log_info "Creating rules for CIDR: $CIDR (rule-number=$RULE_NUM)"

  # Ingress ACCEPT
  aws ec2 create-traffic-mirror-filter-rule \
    --traffic-mirror-filter-id "$MIRROR_FILTER_ID" \
    --traffic-direction ingress \
    --rule-number "$RULE_NUM" \
    --rule-action accept \
    --source-cidr-block "$CIDR" \
    --destination-cidr-block "0.0.0.0/0" || {
      log_warn "Ingress rule $RULE_NUM may already exist, continuing"
    }

  # Egress ACCEPT
  aws ec2 create-traffic-mirror-filter-rule \
    --traffic-mirror-filter-id "$MIRROR_FILTER_ID" \
    --traffic-direction egress \
    --rule-number "$RULE_NUM" \
    --rule-action accept \
    --source-cidr-block "0.0.0.0/0" \
    --destination-cidr-block "$CIDR" || {
      log_warn "Egress rule $RULE_NUM may already exist, continuing"
    }

  RULE_NUM=$((RULE_NUM + 1))
done

# --- Fallback REJECT rules ---
log_info "Creating fallback REJECT rules (rule-number=100)"

aws ec2 create-traffic-mirror-filter-rule \
  --traffic-mirror-filter-id "$MIRROR_FILTER_ID" \
  --traffic-direction ingress \
  --rule-number 100 \
  --rule-action reject \
  --source-cidr-block "0.0.0.0/0" \
  --destination-cidr-block "0.0.0.0/0" || {
    log_warn "Fallback ingress REJECT rule may already exist, continuing"
  }

aws ec2 create-traffic-mirror-filter-rule \
  --traffic-mirror-filter-id "$MIRROR_FILTER_ID" \
  --traffic-direction egress \
  --rule-number 100 \
  --rule-action reject \
  --source-cidr-block "0.0.0.0/0" \
  --destination-cidr-block "0.0.0.0/0" || {
    log_warn "Fallback egress REJECT rule may already exist, continuing"
  }

log_info "Mirror filter setup complete: $MIRROR_FILTER_ID"
