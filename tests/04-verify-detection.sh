#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/scripts/lib/common.sh"
load_config
load_env

# Source test environment
TEST_ENV_FILE="$SCRIPT_DIR/test-env-vars.sh"
if [[ ! -f "$TEST_ENV_FILE" ]]; then
    log_error "Test env file not found: $TEST_ENV_FILE"
    exit 1
fi
source "$TEST_ENV_FILE"

TEST_CONF="$SCRIPT_DIR/test-env.conf"
if [[ -f "$TEST_CONF" ]]; then
    source "$TEST_CONF"
fi

TRAFFIC_DURATION="${TRAFFIC_DURATION:-30}"

require_vars TRAFFIC_GEN_IP_0 TRAFFIC_GEN_IP_1 TRAFFIC_GEN_IP_2 \
             BIZ_HOST_IP_0 BIZ_HOST_IP_1 KEY_PAIR_NAME

KEY_FILE="$PROJECT_DIR/${KEY_PAIR_NAME}.pem"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $KEY_FILE"

# SSH helper: probe instances are in private subnets, use SSM or direct access
# depending on network reachability. Try direct first, fall back to SSM.
ssh_probe() {
    local ip="$1"
    shift
    ssh $SSH_OPTS "ec2-user@${ip}" "$@" 2>/dev/null
}

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

# ========== Stage 1: Wait for probe aggregation flush ==========
stage_header 1 "Wait for Probe Processing"
log_info "Sleeping 15s for probe to flush aggregation window..."
sleep 15

# ========== Stage 2: Collect probe output ==========
stage_header 2 "Collect Probe Output"

# Calculate how far back to look in journal
LOOKBACK_MINUTES=$(( (TRAFFIC_DURATION + 60) / 60 + 2 ))

PROBE_IPS=()
while IFS='=' read -r key value; do
    if [[ "$key" =~ ^PROBE_PRIVATE_IP_ ]]; then
        PROBE_IPS+=("$value")
    fi
done < <(env | grep "^PROBE_PRIVATE_IP_" || true)

if [[ ${#PROBE_IPS[@]} -eq 0 ]]; then
    log_error "No PROBE_PRIVATE_IP_* variables found"
    exit 1
fi

COMBINED_LOG="/tmp/probe-output-combined.log"
> "$COMBINED_LOG"

for i in "${!PROBE_IPS[@]}"; do
    IP="${PROBE_IPS[$i]}"
    OUTPUT_FILE="/tmp/probe-output-${i}.log"
    log_info "Collecting probe output from $IP..."
    ssh_probe "${IP}" \
        "sudo journalctl -u dx-probe --since '${LOOKBACK_MINUTES} minutes ago' --no-pager" \
        > "$OUTPUT_FILE" || true

    LINE_COUNT=$(wc -l < "$OUTPUT_FILE")
    log_info "Probe-${i} ($IP): ${LINE_COUNT} log lines collected"
    cat "$OUTPUT_FILE" >> "$COMBINED_LOG"
done

# ========== Stage 3: Parse and verify rankings ==========
stage_header 3 "Verify Traffic Rankings"

# Extract Report lines containing top_src
REPORT_LINES=$(grep "Report:" "$COMBINED_LOG" 2>/dev/null || true)
REPORT_COUNT=$(echo "$REPORT_LINES" | grep -c "Report:" 2>/dev/null || echo "0")
log_info "Found $REPORT_COUNT Report entries in probe logs"

if [[ "$REPORT_COUNT" -eq 0 ]]; then
    check_fail "No Report entries found in probe logs"
else
    check_pass "Report entries found in probe logs ($REPORT_COUNT)"
fi

# Check Gen-0 (HIGH) appears in top sources
if grep -q "$TRAFFIC_GEN_IP_0" "$COMBINED_LOG" 2>/dev/null; then
    check_pass "Gen-0 ($TRAFFIC_GEN_IP_0) appears in probe logs"
else
    check_fail "Gen-0 ($TRAFFIC_GEN_IP_0) not found in probe logs"
fi

# Check Gen-1 (MEDIUM) appears in probe logs
if grep -q "$TRAFFIC_GEN_IP_1" "$COMBINED_LOG" 2>/dev/null; then
    check_pass "Gen-1 ($TRAFFIC_GEN_IP_1) appears in probe logs"
else
    check_fail "Gen-1 ($TRAFFIC_GEN_IP_1) not found in probe logs"
fi

# Check Gen-2 (LOW) appears in probe logs
if grep -q "$TRAFFIC_GEN_IP_2" "$COMBINED_LOG" 2>/dev/null; then
    check_pass "Gen-2 ($TRAFFIC_GEN_IP_2) appears in probe logs"
else
    check_fail "Gen-2 ($TRAFFIC_GEN_IP_2) not found in probe logs"
fi

# Check BIZ_HOST_IP_0 appears in top destinations (both iperf3 targets)
if grep -q "$BIZ_HOST_IP_0" "$COMBINED_LOG" 2>/dev/null; then
    check_pass "Biz-host-0 ($BIZ_HOST_IP_0) appears in probe logs (iperf3 target)"
else
    check_fail "Biz-host-0 ($BIZ_HOST_IP_0) not found in probe logs"
fi

# Verify Gen-0 bytes > Gen-1 bytes by parsing top_src entries
# The probe logs top_src as: top_src=[('ip', bytes), ...]
# Extract the most recent Report line with both IPs to compare
GEN0_MAX_BYTES=0
GEN1_MAX_BYTES=0

while IFS= read -r line; do
    # Extract bytes for Gen-0 from top_src tuples: ('10.x.x.x', 12345)
    gen0_bytes=$(echo "$line" | grep -oP "'${TRAFFIC_GEN_IP_0//./\\.}',\s*\K[0-9]+" | head -1 || true)
    gen1_bytes=$(echo "$line" | grep -oP "'${TRAFFIC_GEN_IP_1//./\\.}',\s*\K[0-9]+" | head -1 || true)

    if [[ -n "$gen0_bytes" && "$gen0_bytes" -gt "$GEN0_MAX_BYTES" ]]; then
        GEN0_MAX_BYTES="$gen0_bytes"
    fi
    if [[ -n "$gen1_bytes" && "$gen1_bytes" -gt "$GEN1_MAX_BYTES" ]]; then
        GEN1_MAX_BYTES="$gen1_bytes"
    fi
done <<< "$REPORT_LINES"

log_info "Gen-0 max bytes in window: $GEN0_MAX_BYTES"
log_info "Gen-1 max bytes in window: $GEN1_MAX_BYTES"

if [[ "$GEN0_MAX_BYTES" -gt 0 && "$GEN1_MAX_BYTES" -gt 0 ]]; then
    if [[ "$GEN0_MAX_BYTES" -gt "$GEN1_MAX_BYTES" ]]; then
        check_pass "Gen-0 bytes ($GEN0_MAX_BYTES) > Gen-1 bytes ($GEN1_MAX_BYTES) - ranking correct"
    else
        check_fail "Gen-0 bytes ($GEN0_MAX_BYTES) <= Gen-1 bytes ($GEN1_MAX_BYTES) - ranking incorrect"
    fi
elif [[ "$GEN0_MAX_BYTES" -gt 0 ]]; then
    check_pass "Gen-0 bytes ($GEN0_MAX_BYTES) > Gen-1 (not in top_src) - Gen-0 dominant"
else
    check_fail "Could not extract byte counts for ranking comparison"
fi

# ========== Stage 4: Check alert triggering ==========
stage_header 4 "Alert Verification"

ALERT_THRESHOLD_BPS="${ALERT_THRESHOLD_BPS:-1000000000}"
# 500Mbps = 500000000 bps
if [[ "$ALERT_THRESHOLD_BPS" -lt 500000000 ]]; then
    ALERT_LINES=$(grep -c "ALERT triggered" "$COMBINED_LOG" 2>/dev/null || echo "0")
    if [[ "$ALERT_LINES" -gt 0 ]]; then
        check_pass "Alert triggered ($ALERT_LINES occurrences) - threshold ${ALERT_THRESHOLD_BPS} bps < 500Mbps"
    else
        check_fail "Alert not triggered despite threshold ${ALERT_THRESHOLD_BPS} bps < 500Mbps traffic"
    fi
else
    log_info "Alert threshold (${ALERT_THRESHOLD_BPS} bps) >= 500Mbps, skipping alert check"
fi

# ========== Stage 5: Summary ==========
stage_header 5 "Summary"

# Print top-5 sources for visual inspection
echo ""
echo -e "\033[1m--- Top Sources (from latest Report entries) ---\033[0m"
LATEST_REPORT=$(echo "$REPORT_LINES" | tail -5)
if [[ -n "$LATEST_REPORT" ]]; then
    echo "$LATEST_REPORT" | while IFS= read -r line; do
        # Extract just the top_src portion
        src_part=$(echo "$line" | grep -oP 'top_src=\K\[.*?\]' || true)
        if [[ -n "$src_part" ]]; then
            echo "  $src_part"
        fi
    done
else
    echo "  (no report data available)"
fi
echo ""

echo -e "\033[1m=== Verification Results ===\033[0m"
echo -e "  Total checks: $TOTAL"
echo -e "  \033[32mPassed: $PASS\033[0m"
echo -e "  \033[31mFailed: $FAIL\033[0m"
echo ""

if [[ $FAIL -gt 0 ]]; then
    log_warn "${PASS}/${TOTAL} verification checks passed (${FAIL} failed)"
    exit 1
else
    log_info "${PASS}/${TOTAL} verification checks passed"
    exit 0
fi
