#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

require_vars VPC_ID VPC_CIDR ADMIN_CIDR

# ---------- helper: create SG idempotently by Name tag ----------
create_sg_if_not_exists() {
    local sg_name="$1"
    local description="$2"
    local var_name="$3"

    existing=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
                  "Name=tag:Name,Values=${sg_name}" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

    if [[ -n "$existing" && "$existing" != "None" ]]; then
        log_info "Security group ${sg_name} already exists: ${existing}"
        save_var "$var_name" "$existing"
        echo "$existing"
        return 0
    fi

    sg_id=$(aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "$description" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text)

    aws ec2 create-tags --resources "$sg_id" \
        --tags "Key=Name,Value=${sg_name}"
    tag_resource "$sg_id"

    log_info "Created security group ${sg_name}: ${sg_id}"
    save_var "$var_name" "$sg_id"
    echo "$sg_id"
}

# ================================================================
# 1. dx-appliance-sg
# ================================================================
log_info "=== Creating Appliance Security Group ==="
APPLIANCE_SG_ID=$(create_sg_if_not_exists \
    "dx-appliance-sg" \
    "DX Monitoring - Appliance instances (Geneve)" \
    "APPLIANCE_SG_ID")

# Ingress: UDP 6081 (Geneve) from VPC
aws ec2 authorize-security-group-ingress \
    --group-id "$APPLIANCE_SG_ID" \
    --protocol udp --port 6081 \
    --cidr "$VPC_CIDR" 2>/dev/null || log_warn "Ingress UDP/6081 rule already exists"

# Ingress: SSH from ADMIN_CIDR
aws ec2 authorize-security-group-ingress \
    --group-id "$APPLIANCE_SG_ID" \
    --protocol tcp --port 22 \
    --cidr "$ADMIN_CIDR" 2>/dev/null || log_warn "Ingress TCP/22 rule already exists"

# Revoke default egress (0.0.0.0/0) then add VPC-only egress
aws ec2 revoke-security-group-egress \
    --group-id "$APPLIANCE_SG_ID" \
    --protocol all --cidr "0.0.0.0/0" 2>/dev/null || true

aws ec2 authorize-security-group-egress \
    --group-id "$APPLIANCE_SG_ID" \
    --protocol all \
    --cidr "$VPC_CIDR" 2>/dev/null || log_warn "Egress VPC rule already exists"

log_info "Appliance SG configured: ${APPLIANCE_SG_ID}"

# ================================================================
# 2. dx-probe-sg
# ================================================================
log_info "=== Creating Probe Security Group ==="
PROBE_SG_ID=$(create_sg_if_not_exists \
    "dx-probe-sg" \
    "DX Monitoring - Probe instances (VXLAN)" \
    "PROBE_SG_ID")

# Ingress: UDP 4789 (VXLAN) from VPC
aws ec2 authorize-security-group-ingress \
    --group-id "$PROBE_SG_ID" \
    --protocol udp --port 4789 \
    --cidr "$VPC_CIDR" 2>/dev/null || log_warn "Ingress UDP/4789 rule already exists"

# Ingress: SSH from ADMIN_CIDR
aws ec2 authorize-security-group-ingress \
    --group-id "$PROBE_SG_ID" \
    --protocol tcp --port 22 \
    --cidr "$ADMIN_CIDR" 2>/dev/null || log_warn "Ingress TCP/22 rule already exists"

# Revoke default egress then add specific rules
aws ec2 revoke-security-group-egress \
    --group-id "$PROBE_SG_ID" \
    --protocol all --cidr "0.0.0.0/0" 2>/dev/null || true

# Egress: HTTPS to internet (for CloudWatch/SNS API calls)
aws ec2 authorize-security-group-egress \
    --group-id "$PROBE_SG_ID" \
    --protocol tcp --port 443 \
    --cidr "0.0.0.0/0" 2>/dev/null || log_warn "Egress TCP/443 rule already exists"

# Egress: All traffic to VPC
aws ec2 authorize-security-group-egress \
    --group-id "$PROBE_SG_ID" \
    --protocol all \
    --cidr "$VPC_CIDR" 2>/dev/null || log_warn "Egress VPC rule already exists"

log_info "Probe SG configured: ${PROBE_SG_ID}"

log_info "=== Security Groups Complete ==="
log_info "  APPLIANCE_SG_ID = ${APPLIANCE_SG_ID}"
log_info "  PROBE_SG_ID     = ${PROBE_SG_ID}"
