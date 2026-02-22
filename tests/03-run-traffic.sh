#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/scripts/lib/common.sh"
load_config

TEST_ENV_FILE="$SCRIPT_DIR/test-env-vars.sh"
if [[ ! -f "$TEST_ENV_FILE" ]]; then
    log_error "Test env file not found: $TEST_ENV_FILE"
    exit 1
fi
source "$TEST_ENV_FILE"

TEST_CONF="$SCRIPT_DIR/test-env.conf"
[[ -f "$TEST_CONF" ]] && source "$TEST_CONF"

TRAFFIC_DURATION="${TRAFFIC_DURATION:-120}"

require_vars CGW_EIP KEY_PAIR_NAME \
             TRAFFIC_GEN_IP_0 TRAFFIC_GEN_IP_1 TRAFFIC_GEN_IP_2 TRAFFIC_GEN_IP_3 TRAFFIC_GEN_IP_4 \
             BIZ_HOST_IP_0 BIZ_HOST_IP_1 BIZ_HOST_IP_2

KEY_FILE="$PROJECT_DIR/${KEY_PAIR_NAME}.pem"
if [[ ! -f "$KEY_FILE" ]]; then
    log_error "Key file not found: $KEY_FILE"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $KEY_FILE"
JUMP_HOST="ec2-user@${CGW_EIP}"

ssh_gen() {
    local gen_ip="$1"; shift
    ssh $SSH_OPTS -o "ProxyJump=${JUMP_HOST}" "ec2-user@${gen_ip}" "$@"
}

# ================================================================
# 流量模式设计：5 个发生器 -> 3 个业务主机，差异化速率
#
#   Gen-0: 500Mbps iperf3 -> biz-0  (最高, 应排 #1)
#   Gen-1: 200Mbps iperf3 -> biz-0  (高, 应排 #2)
#   Gen-2: 100Mbps iperf3 -> biz-1  (中, 应排 #3)
#   Gen-3:  50Mbps iperf3 -> biz-2  (低, 应排 #4)
#   Gen-4: HTTP curl loop  -> biz-1+biz-2 交替  (最低)
#
#   预期 Probe 排名:
#     Top Source: gen-0 > gen-1 > gen-2 > gen-3 > gen-4
#     Top Dest:   biz-0 (700M) > biz-1 (100M+) > biz-2 (50M+)
# ================================================================

log_info "=== Traffic Generation Plan ==="
log_info "Duration: ${TRAFFIC_DURATION}s"
log_info "Gen-0 (500M): ${TRAFFIC_GEN_IP_0} -> ${BIZ_HOST_IP_0}"
log_info "Gen-1 (200M): ${TRAFFIC_GEN_IP_1} -> ${BIZ_HOST_IP_0}"
log_info "Gen-2 (100M): ${TRAFFIC_GEN_IP_2} -> ${BIZ_HOST_IP_1}"
log_info "Gen-3  (50M): ${TRAFFIC_GEN_IP_3} -> ${BIZ_HOST_IP_2}"
log_info "Gen-4  (HTTP): ${TRAFFIC_GEN_IP_4} -> ${BIZ_HOST_IP_1}+${BIZ_HOST_IP_2}"

# Gen-0: 500Mbps, 4 parallel streams
log_info "Starting Gen-0 (500Mbps)..."
ssh_gen "$TRAFFIC_GEN_IP_0" \
    "nohup iperf3 -c ${BIZ_HOST_IP_0} -b 500M -t ${TRAFFIC_DURATION} -P 4 > /tmp/iperf3.log 2>&1 &"

# Gen-1: 200Mbps, 2 parallel streams
log_info "Starting Gen-1 (200Mbps)..."
ssh_gen "$TRAFFIC_GEN_IP_1" \
    "nohup iperf3 -c ${BIZ_HOST_IP_0} -b 200M -t ${TRAFFIC_DURATION} -P 2 > /tmp/iperf3.log 2>&1 &"

# Gen-2: 100Mbps, single stream
log_info "Starting Gen-2 (100Mbps)..."
ssh_gen "$TRAFFIC_GEN_IP_2" \
    "nohup iperf3 -c ${BIZ_HOST_IP_1} -b 100M -t ${TRAFFIC_DURATION} > /tmp/iperf3.log 2>&1 &"

# Gen-3: 50Mbps, single stream
log_info "Starting Gen-3 (50Mbps)..."
ssh_gen "$TRAFFIC_GEN_IP_3" \
    "nohup iperf3 -c ${BIZ_HOST_IP_2} -b 50M -t ${TRAFFIC_DURATION} > /tmp/iperf3.log 2>&1 &"

# Gen-4: HTTP curl loop alternating biz-1 and biz-2
log_info "Starting Gen-4 (HTTP curl loop)..."
ssh_gen "$TRAFFIC_GEN_IP_4" \
    "nohup bash -c 'END=\$(( \$(date +%s) + ${TRAFFIC_DURATION} )); while [ \$(date +%s) -lt \$END ]; do curl -s -o /dev/null http://${BIZ_HOST_IP_1}/; curl -s -o /dev/null http://${BIZ_HOST_IP_2}/; sleep 0.1; done' > /tmp/curl.log 2>&1 &"

# Wait
WAIT_SEC=$((TRAFFIC_DURATION + 10))
log_info "Waiting ${WAIT_SEC}s for traffic to complete..."
sleep "$WAIT_SEC"

# Cleanup
log_info "Cleaning up traffic processes..."
ALL_GEN_IPS=("$TRAFFIC_GEN_IP_0" "$TRAFFIC_GEN_IP_1" "$TRAFFIC_GEN_IP_2" "$TRAFFIC_GEN_IP_3" "$TRAFFIC_GEN_IP_4")
for GEN_IP in "${ALL_GEN_IPS[@]}"; do
    ssh_gen "$GEN_IP" "pkill -f iperf3 || true; pkill -f curl || true" 2>/dev/null || true
done

log_info "=== Traffic Generation Complete ==="
log_info "Gen-0: 500Mbps -> biz-0 | Gen-1: 200Mbps -> biz-0"
log_info "Gen-2: 100Mbps -> biz-1 | Gen-3: 50Mbps -> biz-2 | Gen-4: HTTP -> biz-1+2"
