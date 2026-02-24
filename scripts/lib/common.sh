#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_DIR/env-vars.sh"

# --- Colored logging ---

log_info() {
    echo -e "\033[0;32m[INFO $(date '+%Y-%m-%d %H:%M:%S')]\033[0m $*"
}

log_warn() {
    echo -e "\033[0;33m[WARN $(date '+%Y-%m-%d %H:%M:%S')]\033[0m $*" >&2
}

log_error() {
    echo -e "\033[0;31m[ERROR $(date '+%Y-%m-%d %H:%M:%S')]\033[0m $*" >&2
}

# --- Config loading ---

load_config() {
    local config_file="$PROJECT_DIR/config/dx-monitor.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$config_file"

    local required_vars=(AWS_REGION VPC_ID VGW_ID VPC_CIDR PROJECT_TAG)
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required config variable $var is not set in $config_file"
            exit 1
        fi
    done
    log_info "Config loaded from $config_file"
}

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        log_info "Environment loaded from $ENV_FILE"
    fi
}

# --- Variable persistence ---

save_var() {
    local name="$1"
    local value="$2"

    if [[ ! -f "$ENV_FILE" ]]; then
        echo "# dx-monitoring environment variables" > "$ENV_FILE"
    fi

    if grep -q "^${name}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${name}=.*|${name}=\"${value}\"|" "$ENV_FILE"
    else
        echo "${name}=\"${value}\"" >> "$ENV_FILE"
    fi
    log_info "Saved $name to $ENV_FILE"
}

check_var_exists() {
    local var_name="$1"
    if [[ ! -f "$ENV_FILE" ]]; then
        return 1
    fi
    grep -q "^${var_name}=" "$ENV_FILE" 2>/dev/null
}

# --- Require non-empty vars ---

require_vars() {
    local missing=0
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required variable $var is not set"
            missing=1
        fi
    done
    if [[ "$missing" -eq 1 ]]; then
        exit 1
    fi
}

# --- Subnet parsing ---

parse_subnets() {
    local var_name="$1"
    local raw="${!var_name}"

    declare -gA SUBNET_MAP=()
    AZ_LIST=()

    IFS=',' read -ra pairs <<< "$raw"
    for pair in "${pairs[@]}"; do
        local az="${pair%%=*}"
        local subnet="${pair##*=}"
        AZ_LIST+=("$az")
        SUBNET_MAP["$az"]="$subnet"
    done
}

# --- AMI resolution ---

get_latest_ami() {
    local region="${AWS_REGION:-ap-northeast-1}"
    local ami_path="/aws/service/ami-amazon-linux-latest"

    local parameters
    parameters=$(aws ssm get-parameters-by-path \
        --path "$ami_path" \
        --region "$region" \
        --query "Parameters[?contains(Name, 'al2023-ami') && contains(Name, 'arm64')].[Name,Value]" \
        --output text)

    if [[ -z "$parameters" ]]; then
        log_error "No AL2023 ARM64 AMI found"
        return 1
    fi

    # Pick the minimal/standard kernel image (not minimal, not kernel-6.x specific)
    local ami_id
    ami_id=$(echo "$parameters" | grep -v "minimal" | grep -v "kernel-6" | head -1 | awk '{print $2}')

    if [[ -z "$ami_id" ]]; then
        # Fallback: just pick the first match
        ami_id=$(echo "$parameters" | head -1 | awk '{print $2}')
    fi

    echo "$ami_id"
}

# --- Polling ---

wait_for_state() {
    local command="$1"
    local expected_state="$2"
    local timeout="${3:-300}"

    local elapsed=0
    local interval=5

    while [[ "$elapsed" -lt "$timeout" ]]; do
        local current_state
        current_state=$(bash -c "$command" 2>/dev/null || true)
        if [[ "$current_state" == "$expected_state" ]]; then
            return 0
        fi
        log_info "Waiting for state '$expected_state' (current: '$current_state', ${elapsed}s/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Timeout after ${timeout}s waiting for state '$expected_state'"
    return 1
}

# --- Resource tagging ---

tag_resource() {
    local resource_id="$1"
    require_vars PROJECT_TAG

    aws ec2 create-tags \
        --resources "$resource_id" \
        --tags "Key=Project,Value=${PROJECT_TAG}" \
        --region "${AWS_REGION:-ap-northeast-1}"
    log_info "Tagged $resource_id with Project=$PROJECT_TAG"
}
