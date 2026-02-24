#!/usr/bin/env bash
# Deploy EventBridge + Lambda for real-time mirror session lifecycle management.
# Creates: IAM role, Lambda function, EventBridge rule.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"
load_config
load_env

DEPLOY_MODE="${DEPLOY_MODE:-gwlb}"
if [[ "$DEPLOY_MODE" != "direct" ]]; then
    log_warn "DEPLOY_MODE=$DEPLOY_MODE — Lambda mirror lifecycle is for 'direct' mode only. Skipping."
    exit 0
fi

require_vars AWS_REGION VPC_ID PROJECT_TAG MIRROR_TARGET_ID MIRROR_FILTER_ID MIRROR_VNI BUSINESS_SUBNET_CIDRS

LAMBDA_NAME="dx-mirror-lifecycle"
ROLE_NAME="dx-mirror-lifecycle-role"

# ================================================================
# Step 1: Resolve business subnet IDs from CIDRs
# ================================================================
SUBNET_IDS=()
IFS=',' read -ra CIDRS <<< "$BUSINESS_SUBNET_CIDRS"
for CIDR in "${CIDRS[@]}"; do
    SID=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$CIDR" \
        --query 'Subnets[0].SubnetId' --output text)
    [[ "$SID" != "None" ]] && SUBNET_IDS+=("$SID")
done
BUSINESS_SUBNET_IDS_CSV=$(IFS=,; echo "${SUBNET_IDS[*]}")
log_info "Business subnet IDs: $BUSINESS_SUBNET_IDS_CSV"

# ================================================================
# Step 2: Create IAM Role for Lambda
# ================================================================
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --tags "Key=Project,Value=$PROJECT_TAG" 2>/dev/null || log_info "Role already exists"

LAMBDA_POLICY='{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Effect":"Allow",
      "Action":[
        "ec2:DescribeInstances",
        "ec2:DescribeTrafficMirrorSessions",
        "ec2:CreateTrafficMirrorSession",
        "ec2:DeleteTrafficMirrorSession",
        "ec2:CreateTags"
      ],
      "Resource":"*"
    },
    {
      "Effect":"Allow",
      "Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
      "Resource":"arn:aws:logs:*:*:*"
    }
  ]
}'

aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "dx-mirror-lifecycle-policy" \
    --policy-document "$LAMBDA_POLICY"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
log_info "Lambda role: $ROLE_ARN"

# Wait for IAM propagation
sleep 10

# ================================================================
# Step 3: Package and deploy Lambda
# ================================================================
LAMBDA_DIR="$PROJECT_DIR/lambda"
ZIP_FILE="/tmp/dx-mirror-lifecycle.zip"

cd "$LAMBDA_DIR"
zip -j "$ZIP_FILE" mirror_lifecycle.py
cd "$PROJECT_DIR"

EXISTING_LAMBDA=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" \
    --query 'Configuration.FunctionArn' --output text 2>/dev/null || echo "NONE")

if [[ "$EXISTING_LAMBDA" == "NONE" ]]; then
    LAMBDA_ARN=$(aws lambda create-function \
        --function-name "$LAMBDA_NAME" \
        --runtime python3.12 \
        --handler mirror_lifecycle.handler \
        --role "$ROLE_ARN" \
        --zip-file "fileb://$ZIP_FILE" \
        --timeout 60 \
        --memory-size 128 \
        --environment "Variables={MIRROR_TARGET_ID=$MIRROR_TARGET_ID,MIRROR_FILTER_ID=$MIRROR_FILTER_ID,MIRROR_VNI=$MIRROR_VNI,BUSINESS_SUBNET_IDS=$BUSINESS_SUBNET_IDS_CSV,PROJECT_TAG=$PROJECT_TAG}" \
        --tags "Project=$PROJECT_TAG" \
        --region "$AWS_REGION" \
        --query 'FunctionArn' --output text)
    log_info "Created Lambda: $LAMBDA_ARN"
else
    aws lambda update-function-code \
        --function-name "$LAMBDA_NAME" \
        --zip-file "fileb://$ZIP_FILE" \
        --region "$AWS_REGION" >/dev/null
    aws lambda update-function-configuration \
        --function-name "$LAMBDA_NAME" \
        --environment "Variables={MIRROR_TARGET_ID=$MIRROR_TARGET_ID,MIRROR_FILTER_ID=$MIRROR_FILTER_ID,MIRROR_VNI=$MIRROR_VNI,BUSINESS_SUBNET_IDS=$BUSINESS_SUBNET_IDS_CSV,PROJECT_TAG=$PROJECT_TAG}" \
        --region "$AWS_REGION" >/dev/null
    LAMBDA_ARN="$EXISTING_LAMBDA"
    log_info "Updated Lambda: $LAMBDA_ARN"
fi

rm -f "$ZIP_FILE"

# ================================================================
# Step 4: Create EventBridge Rule
# ================================================================
RULE_NAME="dx-mirror-ec2-lifecycle"

EVENT_PATTERN='{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 Instance State-change Notification"],
  "detail": {
    "state": ["running", "terminated", "shutting-down", "stopped"]
  }
}'

aws events put-rule \
    --name "$RULE_NAME" \
    --event-pattern "$EVENT_PATTERN" \
    --state ENABLED \
    --tags "Key=Project,Value=$PROJECT_TAG" \
    --region "$AWS_REGION" >/dev/null

log_info "Created EventBridge rule: $RULE_NAME"

# Add Lambda permission for EventBridge
aws lambda add-permission \
    --function-name "$LAMBDA_NAME" \
    --statement-id "EventBridgeInvoke" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "$(aws events describe-rule --name $RULE_NAME --region $AWS_REGION --query 'Arn' --output text)" \
    --region "$AWS_REGION" 2>/dev/null || true

# Add Lambda as target
aws events put-targets \
    --rule "$RULE_NAME" \
    --targets "Id=mirror-lifecycle,Arn=$LAMBDA_ARN" \
    --region "$AWS_REGION" >/dev/null

log_info "EventBridge → Lambda wired"

# ================================================================
# Step 5: Run initial sync for existing instances
# ================================================================
log_info "Running initial mirror sync for existing instances..."
bash "$SCRIPT_DIR/11-business-mirror-sync.sh"

log_info "=== Mirror lifecycle automation deployed ==="
log_info "  Lambda:     $LAMBDA_NAME"
log_info "  EventBridge: $RULE_NAME"
log_info "  Subnets:    $BUSINESS_SUBNET_IDS_CSV"
