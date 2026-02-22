#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/scripts/lib/common.sh"
load_config

# Source test environment
TEST_ENV_FILE="$SCRIPT_DIR/test-env-vars.sh"
if [[ ! -f "$TEST_ENV_FILE" ]]; then
    log_error "Test env file not found: $TEST_ENV_FILE"
    exit 1
fi
source "$TEST_ENV_FILE"

# Source test config
TEST_CONF="$SCRIPT_DIR/test-env.conf"
if [[ -f "$TEST_CONF" ]]; then
    source "$TEST_CONF"
fi

TRAFFIC_DURATION="${TRAFFIC_DURATION:-30}"

require_vars CGW_EIP TRAFFIC_GEN_IP_0 TRAFFIC_GEN_IP_1 TRAFFIC_GEN_IP_2 \
             BIZ_HOST_IP_0 BIZ_HOST_IP_1 KEY_PAIR_NAME

KEY_FILE="$PROJECT_DIR/${KEY_PAIR_NAME}.pem"
if [[ ! -f "$KEY_FILE" ]]; then
    log_error "Key file not found: $KEY_FILE"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $KEY_FILE"
JUMP_HOST="ec2-user@${CGW_EIP}"

ssh_gen() {
    local gen_ip="$1"
    shift
    ssh $SSH_OPTS -o "ProxyJump=${JUMP_HOST}" "ec2-user@${gen_ip}" "$@"
}

log_info "=== Traffic Generation ==="
log_info "Duration: ${TRAFFIC_DURATION}s"
log_info "Gen-0 (HIGH):   ${TRAFFIC_GEN_IP_0} -> ${BIZ_HOST_IP_0} @ 500Mbps iperf3"
log_info "Gen-1 (MEDIUM): ${TRAFFIC_GEN_IP_1} -> ${BIZ_HOST_IP_0} @ 100Mbps iperf3"
log_info "Gen-2 (LOW):    ${TRAFFIC_GEN_IP_2} -> ${BIZ_HOST_IP_1} HTTP curl loop"

# --- Gen-0: HIGH traffic (500Mbps iperf3) ---
log_info "Starting Gen-0 (HIGH) on ${TRAFFIC_GEN_IP_0}..."
ssh_gen "$TRAFFIC_GEN_IP_0" "nohup iperf3 -c ${BIZ_HOST_IP_0} -b 500M -t ${TRAFFIC_DURATION} -P 4 > /tmp/iperf3-gen0.log 2>&1 &"

# --- Gen-1: MEDIUM traffic (100Mbps iperf3) ---
log_info "Starting Gen-1 (MEDIUM) on ${TRAFFIC_GEN_IP_1}..."
ssh_gen "$TRAFFIC_GEN_IP_1" "nohup iperf3 -c ${BIZ_HOST_IP_0} -b 100M -t ${TRAFFIC_DURATION} -P 2 > /tmp/iperf3-gen1.log 2>&1 &"

# --- Gen-2: LOW traffic (curl loop) ---
log_info "Starting Gen-2 (LOW) on ${TRAFFIC_GEN_IP_2}..."
ssh_gen "$TRAFFIC_GEN_IP_2" "nohup bash -c 'END=\$(( \$(date +%s) + ${TRAFFIC_DURATION} )); while [ \$(date +%s) -lt \$END ]; do curl -s -o /dev/null http://${BIZ_HOST_IP_1}/ ; sleep 0.1; done' > /tmp/curl-gen2.log 2>&1 &"

# --- Wait for traffic to complete ---
WAIT_SECONDS=$((TRAFFIC_DURATION + 10))
log_info "Waiting ${WAIT_SECONDS}s for traffic to complete..."
sleep "$WAIT_SECONDS"

# --- Kill any remaining traffic processes ---
log_info "Cleaning up remaining traffic processes..."
for GEN_IP in "$TRAFFIC_GEN_IP_0" "$TRAFFIC_GEN_IP_1" "$TRAFFIC_GEN_IP_2"; do
    ssh_gen "$GEN_IP" "pkill -f iperf3 || true; pkill -f 'curl.*${BIZ_HOST_IP_1}' || true" 2>/dev/null || true
done

# --- Summary ---
log_info "=== Traffic Generation Summary ==="
log_info "Gen-0 (HIGH):   500Mbps x ${TRAFFIC_DURATION}s  -> ${BIZ_HOST_IP_0}"
log_info "Gen-1 (MEDIUM): 100Mbps x ${TRAFFIC_DURATION}s  -> ${BIZ_HOST_IP_0}"
log_info "Gen-2 (LOW):    HTTP curl x ${TRAFFIC_DURATION}s -> ${BIZ_HOST_IP_1}"
log_info "Traffic generation complete"
