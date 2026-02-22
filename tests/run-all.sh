#!/usr/bin/env bash
set -euo pipefail
# Usage: ./tests/run-all.sh [--skip-infra] [--skip-cleanup]
#
# Full test sequence:
# 1. Setup test infrastructure (VPN + on-prem sim)
# 2. Launch business hosts
# 3. Launch traffic generators
# 4. Wait for VPN tunnel UP + instances ready
# 5. Run traffic generation
# 6. Verify probe detection
# 7. Cleanup (unless --skip-cleanup)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/scripts/lib/common.sh"

SKIP_INFRA=false
SKIP_CLEANUP=false

for arg in "$@"; do
    case "$arg" in
        --skip-infra)   SKIP_INFRA=true ;;
        --skip-cleanup) SKIP_CLEANUP=true ;;
        *)
            log_error "Unknown flag: $arg"
            echo "Usage: $0 [--skip-infra] [--skip-cleanup]"
            exit 1
            ;;
    esac
done

FINAL_RESULT=0

run_step() {
    local step_num="$1"
    local desc="$2"
    local script="$3"

    echo ""
    log_info "========================================="
    log_info "Step ${step_num}: ${desc}"
    log_info "========================================="

    if [[ ! -f "$script" ]]; then
        log_error "Script not found: $script"
        return 1
    fi

    if bash "$script"; then
        log_info "Step ${step_num} PASSED"
        return 0
    else
        log_error "Step ${step_num} FAILED"
        return 1
    fi
}

cleanup() {
    if [[ "$SKIP_CLEANUP" == "true" ]]; then
        log_warn "Skipping cleanup (--skip-cleanup). Run: tests/99-test-cleanup.sh"
        return
    fi
    echo ""
    log_info "========================================="
    log_info "Cleanup"
    log_info "========================================="
    bash "$SCRIPT_DIR/99-test-cleanup.sh" --force || true
}

# Register cleanup on exit unless skipped
if [[ "$SKIP_CLEANUP" != "true" ]]; then
    trap cleanup EXIT
fi

# --- Infrastructure setup ---
if [[ "$SKIP_INFRA" != "true" ]]; then
    run_step 1 "Setup on-prem VPC + VPN" "$SCRIPT_DIR/00-test-infra.sh" || { FINAL_RESULT=1; exit 1; }
    run_step 2 "Launch business hosts" "$SCRIPT_DIR/01-business-hosts.sh" || { FINAL_RESULT=1; exit 1; }
    run_step 3 "Launch traffic generators" "$SCRIPT_DIR/02-traffic-gen.sh" || { FINAL_RESULT=1; exit 1; }
else
    log_info "Skipping infrastructure setup (--skip-infra)"
    if [[ ! -f "$SCRIPT_DIR/test-env-vars.sh" ]]; then
        log_error "Cannot skip infra: test-env-vars.sh not found"
        exit 1
    fi
fi

# --- Traffic generation ---
run_step 4 "Run traffic generation" "$SCRIPT_DIR/03-run-traffic.sh" || { FINAL_RESULT=1; exit 1; }

# --- Verification ---
run_step 5 "Verify probe detection" "$SCRIPT_DIR/04-verify-detection.sh" || FINAL_RESULT=1

# --- Final result ---
echo ""
log_info "========================================="
if [[ $FINAL_RESULT -eq 0 ]]; then
    log_info "FINAL RESULT: PASS"
else
    log_error "FINAL RESULT: FAIL"
fi
log_info "========================================="

exit $FINAL_RESULT
