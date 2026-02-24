#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

require_vars VPC_ID VPC_CIDR ADMIN_CIDR

# ---------- helper: create SG idempotently by Name tag ----------
# Returns SG ID via stdout. All log output goes to stderr to avoid
# polluting the captured value when called via $().
create_sg_if_not_exists() {
    local sg_name="$1"
    local description="$2"
    local var_name="$3"

    existing=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
                  "Name=tag:Name,Values=${sg_name}" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

    if [[ -n "$existing" && "$existing" != "None" ]]; then
        log_info "Security group ${sg_name} already exists: ${existing}" >&2
        save_var "$var_name" "$existing" >&2
        echo "$existing"
        return 0
    fi

    sg_id=$(aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "$description" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text)

    aws ec2 create-tags --resources "$sg_id" \
        --tags "Key=Name,Value=${sg_name}" >&2
    tag_resource "$sg_id" >&2

    log_info "Created security group ${sg_name}: ${sg_id}" >&2
    save_var "$var_name" "$sg_id" >&2
    echo "$sg_id"
}

# ---------- helper: add SG rule idempotently ----------
# Properly distinguishes "duplicate rule" from real errors.
ensure_sg_ingress() {
    local sg_id="$1"; shift
    local output
    if output=$(aws ec2 authorize-security-group-ingress --group-id "$sg_id" "$@" 2>&1); then
        log_info "Added ingress rule to $sg_id"
    elif echo "$output" | grep -q "InvalidPermission.Duplicate"; then
        log_info "Ingress rule already exists on $sg_id (skipped)"
    else
        log_error "Failed to add ingress rule to $sg_id: $output"
        return 1
    fi
}

ensure_sg_egress() {
    local sg_id="$1"; shift
    local output
    if output=$(aws ec2 authorize-security-group-egress --group-id "$sg_id" "$@" 2>&1); then
        log_info "Added egress rule to $sg_id"
    elif echo "$output" | grep -q "InvalidPermission.Duplicate"; then
        log_info "Egress rule already exists on $sg_id (skipped)"
    else
        log_error "Failed to add egress rule to $sg_id: $output"
        return 1
    fi
}

# ================================================================
# 1. dx-appliance-sg (gwlb mode only)
# ================================================================
DEPLOY_MODE="${DEPLOY_MODE:-gwlb}"

if [[ "$DEPLOY_MODE" == "gwlb" ]]; then
    log_info "=== Creating Appliance Security Group ==="
    APPLIANCE_SG_ID=$(create_sg_if_not_exists \
        "dx-appliance-sg" \
        "DX Monitoring - Appliance instances (Geneve)" \
        "APPLIANCE_SG_ID")

    ensure_sg_ingress "$APPLIANCE_SG_ID" --protocol udp --port 6081 --cidr "$VPC_CIDR"
    ensure_sg_ingress "$APPLIANCE_SG_ID" --protocol tcp --port 22 --cidr "$ADMIN_CIDR"

    aws ec2 revoke-security-group-egress \
        --group-id "$APPLIANCE_SG_ID" \
        --protocol all --cidr "0.0.0.0/0" 2>/dev/null || true

    ensure_sg_egress "$APPLIANCE_SG_ID" --protocol all --cidr "$VPC_CIDR"

    log_info "Appliance SG configured: ${APPLIANCE_SG_ID}"
else
    log_info "=== Skipping Appliance SG (DEPLOY_MODE=direct) ==="
fi

# ================================================================
# 2. dx-probe-sg
# ================================================================
log_info "=== Creating Probe Security Group ==="
PROBE_SG_ID=$(create_sg_if_not_exists \
    "dx-probe-sg" \
    "DX Monitoring - Probe instances (VXLAN)" \
    "PROBE_SG_ID")

ensure_sg_ingress "$PROBE_SG_ID" --protocol udp --port 4789 --cidr "$VPC_CIDR"
ensure_sg_ingress "$PROBE_SG_ID" --protocol tcp --port 22 --cidr "$ADMIN_CIDR"
ensure_sg_ingress "$PROBE_SG_ID" --protocol tcp --port 22 --cidr "$VPC_CIDR"

aws ec2 revoke-security-group-egress \
    --group-id "$PROBE_SG_ID" \
    --protocol all --cidr "0.0.0.0/0" 2>/dev/null || true

ensure_sg_egress "$PROBE_SG_ID" --protocol tcp --port 443 --cidr "0.0.0.0/0"
ensure_sg_egress "$PROBE_SG_ID" --protocol all --cidr "$VPC_CIDR"

log_info "Probe SG configured: ${PROBE_SG_ID}"

log_info "=== Security Groups Complete ==="
if [[ "$DEPLOY_MODE" == "gwlb" ]]; then
    log_info "  APPLIANCE_SG_ID = ${APPLIANCE_SG_ID}"
fi
log_info "  PROBE_SG_ID     = ${PROBE_SG_ID}"
