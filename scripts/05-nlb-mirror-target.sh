#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

DEPLOY_MODE="${DEPLOY_MODE:-gwlb}"

if [[ "$DEPLOY_MODE" == "direct" ]]; then
  # --- Direct mode: Mirror target points to Probe ENI (no NLB) ---
  require_vars PROBE_INSTANCE_ID_0

  if check_var_exists MIRROR_TARGET_ID; then
    log_info "Mirror target already exists, skipping"
  else
    log_info "Getting Probe 0 primary ENI..."
    PROBE_ENI=$(aws ec2 describe-instances --instance-ids "$PROBE_INSTANCE_ID_0" \
      --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
    log_info "Probe 0 primary ENI: $PROBE_ENI"

    log_info "Creating traffic mirror target (ENI-direct)..."
    MIRROR_TARGET_ID=$(aws ec2 create-traffic-mirror-target \
      --network-interface-id "$PROBE_ENI" \
      --tag-specifications "ResourceType=traffic-mirror-target,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" \
      --query 'TrafficMirrorTarget.TrafficMirrorTargetId' --output text)

    save_var MIRROR_TARGET_ID "$MIRROR_TARGET_ID"
    log_info "Created mirror target: $MIRROR_TARGET_ID (ENI: $PROBE_ENI)"
  fi

  log_info "Mirror target setup complete (direct mode, no NLB)"

else
  # --- GWLB mode: NLB as mirror target ---
  require_vars VPC_ID WORKLOAD_SUBNETS

  # Dynamically discover all probe instances
  PROBE_INSTANCE_IDS=()
  IDX=0
  while true; do
      VAR_NAME="PROBE_INSTANCE_ID_${IDX}"
      if [[ -n "${!VAR_NAME:-}" ]]; then
          PROBE_INSTANCE_IDS+=("${!VAR_NAME}")
          IDX=$((IDX + 1))
      else
          break
      fi
  done

  if [[ ${#PROBE_INSTANCE_IDS[@]} -eq 0 ]]; then
      log_error "No PROBE_INSTANCE_ID_* variables found in env-vars.sh"
      exit 1
  fi
  log_info "Found ${#PROBE_INSTANCE_IDS[@]} probe instance(s)"

  parse_subnets WORKLOAD_SUBNETS

  # Collect subnet IDs for NLB
  SUBNET_IDS=()
  for AZ in "${AZ_LIST[@]}"; do
    SUBNET_IDS+=("${SUBNET_MAP[$AZ]}")
  done

  # --- Target Group ---
  if check_var_exists MIRROR_TG_ARN; then
    log_info "Mirror target group already exists, skipping"
  else
    log_info "Creating UDP target group for mirror traffic..."
    MIRROR_TG_ARN=$(aws elbv2 create-target-group \
      --name dx-mirror-tg \
      --protocol UDP \
      --port 4789 \
      --vpc-id "$VPC_ID" \
      --target-type instance \
      --health-check-protocol TCP \
      --health-check-port 22 \
      --query 'TargetGroups[0].TargetGroupArn' --output text)

    save_var MIRROR_TG_ARN "$MIRROR_TG_ARN"
    log_info "Created target group: $MIRROR_TG_ARN"
  fi

  load_env

  # --- NLB ---
  if check_var_exists NLB_ARN; then
    log_info "NLB already exists, skipping"
  else
    log_info "Creating internal NLB..."
    NLB_ARN=$(aws elbv2 create-load-balancer \
      --name dx-mirror-nlb \
      --type network \
      --scheme internal \
      --subnets "${SUBNET_IDS[@]}" \
      --tags "Key=Project,Value=${PROJECT_TAG}" \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text)

    save_var NLB_ARN "$NLB_ARN"
    log_info "Created NLB: $NLB_ARN"

    # Disable cross-zone to avoid cross-AZ transfer fees (single-AZ deployment)
    aws elbv2 modify-load-balancer-attributes \
      --load-balancer-arn "$NLB_ARN" \
      --attributes Key=load_balancing.cross_zone.enabled,Value=false
    log_info "Cross-zone load balancing disabled (single-AZ cost optimization)"
  fi

  load_env

  # --- Listener ---
  log_info "Creating UDP listener on port 4789..."
  EXISTING_LISTENERS=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$NLB_ARN" \
    --query 'Listeners[?Port==`4789`].ListenerArn' --output text)

  if [[ -z "$EXISTING_LISTENERS" ]]; then
    aws elbv2 create-listener \
      --load-balancer-arn "$NLB_ARN" \
      --protocol UDP \
      --port 4789 \
      --default-actions "Type=forward,TargetGroupArn=${MIRROR_TG_ARN}"
    log_info "Created UDP listener"
  else
    log_info "Listener already exists, skipping"
  fi

  # --- Register Targets ---
  log_info "Registering probe instances as targets..."
  TARGETS=()
  for IID in "${PROBE_INSTANCE_IDS[@]}"; do
      TARGETS+=("Id=${IID}")
  done
  aws elbv2 register-targets \
      --target-group-arn "$MIRROR_TG_ARN" \
      --targets "${TARGETS[@]}"
  log_info "Registered ${#PROBE_INSTANCE_IDS[@]} probe instance(s)"

  # --- Wait for NLB active ---
  log_info "Waiting for NLB to become active..."
  aws elbv2 wait load-balancer-available --load-balancer-arns "$NLB_ARN"
  log_info "NLB is active"

  # --- Traffic Mirror Target ---
  if check_var_exists MIRROR_TARGET_ID; then
    log_info "Mirror target already exists, skipping"
  else
    log_info "Creating traffic mirror target..."
    MIRROR_TARGET_ID=$(aws ec2 create-traffic-mirror-target \
      --network-load-balancer-arn "$NLB_ARN" \
      --tag-specifications "ResourceType=traffic-mirror-target,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" \
      --query 'TrafficMirrorTarget.TrafficMirrorTargetId' --output text)

    save_var MIRROR_TARGET_ID "$MIRROR_TARGET_ID"
    log_info "Created mirror target: $MIRROR_TARGET_ID"
  fi

  log_info "NLB and mirror target setup complete"
fi
