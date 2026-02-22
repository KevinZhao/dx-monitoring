#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/scripts/lib/common.sh"
load_config
load_env

TEST_ENV_FILE="$SCRIPT_DIR/test-env-vars.sh"
if [[ ! -f "$TEST_ENV_FILE" ]]; then
    log_error "Test env file not found: $TEST_ENV_FILE"
    exit 1
fi
source "$TEST_ENV_FILE"

TEST_CONF="$SCRIPT_DIR/test-env.conf"
[[ -f "$TEST_CONF" ]] && source "$TEST_CONF"

TRAFFIC_DURATION="${TRAFFIC_DURATION:-120}"

require_vars TRAFFIC_GEN_IP_0 TRAFFIC_GEN_IP_1 TRAFFIC_GEN_IP_2 TRAFFIC_GEN_IP_3 TRAFFIC_GEN_IP_4 \
             BIZ_HOST_IP_0 BIZ_HOST_IP_1 BIZ_HOST_IP_2 KEY_PAIR_NAME

KEY_FILE="$PROJECT_DIR/${KEY_PAIR_NAME}.pem"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $KEY_FILE"

ssh_probe() {
    local ip="$1"; shift
    ssh $SSH_OPTS "ec2-user@${ip}" "$@" 2>/dev/null
}

PASS=0; FAIL=0; TOTAL=0

check_pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "  \033[32m[PASS]\033[0m $1"; }
check_fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "  \033[31m[FAIL]\033[0m $1"; }
stage_header() { echo ""; echo -e "\033[1;36m=== Stage $1: $2 ===\033[0m"; }

# ========== Stage 1: Wait for flush ==========
stage_header 1 "Wait for Probe Processing"
log_info "Sleeping 15s for probe aggregation flush..."
sleep 15

# ========== Stage 2: Collect probe output ==========
stage_header 2 "Collect Probe Output"

LOOKBACK_MINUTES=$(( (TRAFFIC_DURATION + 60) / 60 + 2 ))

PROBE_IPS=()
while IFS='=' read -r key value; do
    value="${value//\"/}"
    [[ -n "$value" ]] && PROBE_IPS+=("$value")
done < <(grep "^PROBE_PRIVATE_IP_" "$PROJECT_DIR/env-vars.sh" 2>/dev/null || true)

if [[ ${#PROBE_IPS[@]} -eq 0 ]]; then
    log_error "No PROBE_PRIVATE_IP_* found in env-vars.sh"
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
    log_info "Probe-${i} ($IP): ${LINE_COUNT} lines"
    cat "$OUTPUT_FILE" >> "$COMBINED_LOG"
done

# ========== Stage 3: Verify source rankings ==========
stage_header 3 "Verify Source Rankings"

REPORT_LINES=$(grep "Report:" "$COMBINED_LOG" 2>/dev/null || true)
REPORT_COUNT=$(echo "$REPORT_LINES" | grep -c "Report:" 2>/dev/null || echo "0")
log_info "Found $REPORT_COUNT Report entries"

if [[ "$REPORT_COUNT" -eq 0 ]]; then
    check_fail "No Report entries found in probe logs"
else
    check_pass "Report entries found ($REPORT_COUNT)"
fi

# Check each generator IP appears in logs
ALL_GEN_IPS=("$TRAFFIC_GEN_IP_0" "$TRAFFIC_GEN_IP_1" "$TRAFFIC_GEN_IP_2" "$TRAFFIC_GEN_IP_3" "$TRAFFIC_GEN_IP_4")
GEN_LABELS=("Gen-0(500M)" "Gen-1(200M)" "Gen-2(100M)" "Gen-3(50M)" "Gen-4(HTTP)")

for idx in "${!ALL_GEN_IPS[@]}"; do
    if grep -q "${ALL_GEN_IPS[$idx]}" "$COMBINED_LOG" 2>/dev/null; then
        check_pass "${GEN_LABELS[$idx]} (${ALL_GEN_IPS[$idx]}) appears in probe logs"
    else
        check_fail "${GEN_LABELS[$idx]} (${ALL_GEN_IPS[$idx]}) not found in probe logs"
    fi
done

# Extract bytes per source from top_src tuples: ('ip', bytes)
extract_max_bytes() {
    local ip="$1"
    local escaped_ip="${ip//./\\.}"
    local max_bytes=0
    while IFS= read -r line; do
        local b
        b=$(echo "$line" | grep -oP "'${escaped_ip}',\s*\K[0-9]+" | head -1 || true)
        if [[ -n "$b" && "$b" -gt "$max_bytes" ]]; then
            max_bytes="$b"
        fi
    done <<< "$REPORT_LINES"
    echo "$max_bytes"
}

GEN0_BYTES=$(extract_max_bytes "$TRAFFIC_GEN_IP_0")
GEN1_BYTES=$(extract_max_bytes "$TRAFFIC_GEN_IP_1")
GEN2_BYTES=$(extract_max_bytes "$TRAFFIC_GEN_IP_2")
GEN3_BYTES=$(extract_max_bytes "$TRAFFIC_GEN_IP_3")

log_info "Peak bytes per window: Gen-0=$GEN0_BYTES Gen-1=$GEN1_BYTES Gen-2=$GEN2_BYTES Gen-3=$GEN3_BYTES"

# Verify ranking: Gen-0 > Gen-1 > Gen-2 > Gen-3
if [[ "$GEN0_BYTES" -gt 0 && "$GEN1_BYTES" -gt 0 && "$GEN0_BYTES" -gt "$GEN1_BYTES" ]]; then
    check_pass "Gen-0($GEN0_BYTES) > Gen-1($GEN1_BYTES) - top source correct"
else
    check_fail "Gen-0($GEN0_BYTES) should be > Gen-1($GEN1_BYTES)"
fi

if [[ "$GEN1_BYTES" -gt 0 && "$GEN2_BYTES" -gt 0 && "$GEN1_BYTES" -gt "$GEN2_BYTES" ]]; then
    check_pass "Gen-1($GEN1_BYTES) > Gen-2($GEN2_BYTES) - second source correct"
else
    check_fail "Gen-1($GEN1_BYTES) should be > Gen-2($GEN2_BYTES)"
fi

if [[ "$GEN2_BYTES" -gt 0 && "$GEN3_BYTES" -gt 0 && "$GEN2_BYTES" -gt "$GEN3_BYTES" ]]; then
    check_pass "Gen-2($GEN2_BYTES) > Gen-3($GEN3_BYTES) - third source correct"
else
    check_fail "Gen-2($GEN2_BYTES) should be > Gen-3($GEN3_BYTES)"
fi

# ========== Stage 4: Verify destination rankings ==========
stage_header 4 "Verify Destination Rankings"

# biz-0 receives 500M+200M=700M, should be top destination
ALL_BIZ_IPS=("$BIZ_HOST_IP_0" "$BIZ_HOST_IP_1" "$BIZ_HOST_IP_2")
BIZ_LABELS=("biz-0(700M target)" "biz-1(100M+ target)" "biz-2(50M+ target)")

for idx in "${!ALL_BIZ_IPS[@]}"; do
    if grep -q "${ALL_BIZ_IPS[$idx]}" "$COMBINED_LOG" 2>/dev/null; then
        check_pass "${BIZ_LABELS[$idx]} (${ALL_BIZ_IPS[$idx]}) appears in probe logs"
    else
        check_fail "${BIZ_LABELS[$idx]} (${ALL_BIZ_IPS[$idx]}) not found in probe logs"
    fi
done

# ========== Stage 5: Alert verification ==========
stage_header 5 "Alert Verification"

ALERT_THRESHOLD_BPS="${ALERT_THRESHOLD_BPS:-1000000000}"
if [[ "$ALERT_THRESHOLD_BPS" -lt 500000000 ]]; then
    ALERT_LINES=$(grep -c "ALERT triggered" "$COMBINED_LOG" 2>/dev/null || echo "0")
    if [[ "$ALERT_LINES" -gt 0 ]]; then
        check_pass "Alert triggered ($ALERT_LINES occurrences)"
    else
        check_fail "Alert not triggered (threshold=${ALERT_THRESHOLD_BPS} < 500Mbps)"
    fi
else
    log_info "Alert threshold (${ALERT_THRESHOLD_BPS}) >= 500Mbps, skip alert check"
fi

# ========== Stage 6: Summary ==========
stage_header 6 "Summary"

echo ""
echo -e "\033[1m--- Latest Top Sources ---\033[0m"
echo "$REPORT_LINES" | tail -3 | while IFS= read -r line; do
    src_part=$(echo "$line" | grep -oP 'top_src=\K\[.*?\]' || true)
    [[ -n "$src_part" ]] && echo "  $src_part"
done

echo ""
echo -e "\033[1m--- Latest Top Destinations ---\033[0m"
echo "$REPORT_LINES" | tail -3 | while IFS= read -r line; do
    dst_part=$(echo "$line" | grep -oP 'top_dst=\K\[.*?\]' || true)
    [[ -n "$dst_part" ]] && echo "  $dst_part"
done

echo ""
echo -e "\033[1m=== Verification Results ===\033[0m"
echo -e "  Total: $TOTAL | \033[32mPassed: $PASS\033[0m | \033[31mFailed: $FAIL\033[0m"

if [[ $FAIL -gt 0 ]]; then
    log_warn "${PASS}/${TOTAL} checks passed (${FAIL} failed)"
    exit 1
else
    log_info "${PASS}/${TOTAL} checks passed"
    exit 0
fi
