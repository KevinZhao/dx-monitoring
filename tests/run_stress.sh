#!/bin/bash
set -ex

BUCKET="dx-monitoring-deploy-REDACTED-ACCOUNT-ID"
NLB_DNS="$1"
DURATION="${2:-30}"
THREADS="${3:-8}"

# Install deps
yum install -y gcc 2>/dev/null || true

# Download and compile flood tool
aws s3 cp "s3://$BUCKET/vxlan_flood.c" /tmp/vxlan_flood.c --region eu-central-1
gcc -O2 -o /tmp/vxlan_flood /tmp/vxlan_flood.c -lpthread
echo "Compiled vxlan_flood"

# Resolve NLB IP
NLB_IP=$(getent hosts "$NLB_DNS" | head -1 | awk '{print $1}')
echo "NLB DNS: $NLB_DNS -> IP: $NLB_IP"

# Run flood
echo "Starting VXLAN flood: target=$NLB_IP:4789 threads=$THREADS duration=${DURATION}s"
/tmp/vxlan_flood "$NLB_IP" 4789 "$THREADS" "$DURATION"
echo "Flood complete"
