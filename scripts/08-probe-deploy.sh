#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

# Deploy probe software to all Probe instances

require_vars KEY_PAIR_NAME AWS_REGION ALERT_THRESHOLD_BPS ALERT_THRESHOLD_PPS VPC_ID

KEY_FILE="$PROJECT_DIR/${KEY_PAIR_NAME}.pem"
if [[ ! -f "$KEY_FILE" ]]; then
    log_error "Key file not found: $KEY_FILE"
    exit 1
fi

KEY_PERMS=$(stat -c "%a" "$KEY_FILE" 2>/dev/null || stat -f "%Lp" "$KEY_FILE" 2>/dev/null)
if [[ "$KEY_PERMS" != "600" && "$KEY_PERMS" != "400" ]]; then
    log_warn "Key file has permissions $KEY_PERMS, fixing to 600"
    chmod 600 "$KEY_FILE"
fi

PROBE_DIR="$PROJECT_DIR/probe"
if [[ ! -d "$PROBE_DIR" ]]; then
    log_error "Probe directory not found: $PROBE_DIR"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -i $KEY_FILE"

# Collect probe IPs from env-vars
PROBE_IPS=()
IDX=0
while true; do
    VAR_NAME="PROBE_PRIVATE_IP_${IDX}"
    if [[ -n "${!VAR_NAME:-}" ]]; then
        PROBE_IPS+=("${!VAR_NAME}")
        IDX=$((IDX + 1))
    else
        break
    fi
done

if [[ ${#PROBE_IPS[@]} -eq 0 ]]; then
    log_error "No PROBE_PRIVATE_IP_* variables found in env-vars.sh"
    exit 1
fi

log_info "Deploying probe to ${#PROBE_IPS[@]} instance(s)"

SYSTEMD_UNIT="[Unit]
Description=DX Traffic Monitor Probe
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /home/ec2-user/probe/multiproc_probe.py
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=AWS_REGION=${AWS_REGION}
Environment=SNS_TOPIC_ARN=${SNS_TOPIC_ARN}
Environment=ALERT_THRESHOLD_BPS=${ALERT_THRESHOLD_BPS}
Environment=ALERT_THRESHOLD_PPS=${ALERT_THRESHOLD_PPS}
Environment=ALERT_HOST_BPS=${ALERT_HOST_BPS:-0}
Environment=ALERT_HOST_PPS=${ALERT_HOST_PPS:-0}
Environment=SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL:-}
Environment=VPC_ID=${VPC_ID}
Environment=PROBE_WORKERS=0
Environment=PROBE_SAMPLE_RATE=1.0

[Install]
WantedBy=multi-user.target"

for IP in "${PROBE_IPS[@]}"; do
    log_info "--- Deploying to $IP ---"

    # Copy probe directory
    log_info "Copying probe/ to $IP"
    scp $SSH_OPTS -r "$PROBE_DIR" "ec2-user@${IP}:~/"

    # Install dependencies
    log_info "Installing Python dependencies on $IP"
    ssh $SSH_OPTS "ec2-user@${IP}" "pip3 install -r ~/probe/requirements.txt"

    # Create systemd service
    log_info "Creating systemd service on $IP"
    ssh $SSH_OPTS "ec2-user@${IP}" "sudo tee /etc/systemd/system/dx-probe.service > /dev/null << 'UNIT_EOF'
${SYSTEMD_UNIT}
UNIT_EOF"

    # Enable and start
    log_info "Starting dx-probe service on $IP"
    ssh $SSH_OPTS "ec2-user@${IP}" "sudo systemctl daemon-reload && sudo systemctl enable dx-probe && sudo systemctl start dx-probe"

    # Verify
    STATUS=$(ssh $SSH_OPTS "ec2-user@${IP}" "sudo systemctl is-active dx-probe" || true)
    if [[ "$STATUS" == "active" ]]; then
        log_info "dx-probe is active on $IP"
    else
        log_error "dx-probe failed to start on $IP (status: $STATUS)"
        exit 1
    fi
done

log_info "Probe deployed to all ${#PROBE_IPS[@]} instance(s)"
