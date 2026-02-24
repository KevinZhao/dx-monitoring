"""
EventBridge Lambda: auto-create/delete Traffic Mirror sessions on EC2 lifecycle events.

Triggered by:
  - EC2 Instance State-change: running → create mirror session
  - EC2 Instance State-change: terminated/stopped → delete mirror session

Environment variables:
  MIRROR_TARGET_ID  - Traffic Mirror Target (NLB)
  MIRROR_FILTER_ID  - Traffic Mirror Filter
  MIRROR_VNI        - Virtual Network ID (default: 12345)
  BUSINESS_SUBNET_IDS - Comma-separated subnet IDs to monitor
  PROJECT_TAG       - Project tag for resource management
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client("ec2")

MIRROR_TARGET_ID = os.environ["MIRROR_TARGET_ID"]
MIRROR_FILTER_ID = os.environ["MIRROR_FILTER_ID"]
MIRROR_VNI = int(os.environ.get("MIRROR_VNI", "12345"))
BUSINESS_SUBNET_IDS = set(
    s.strip() for s in os.environ.get("BUSINESS_SUBNET_IDS", "").split(",") if s.strip()
)
PROJECT_TAG = os.environ.get("PROJECT_TAG", "dx-monitoring")
MANAGED_TAG = "dx-mirror-auto"


def handler(event, context):
    logger.info("Event: %s", json.dumps(event))

    detail = event.get("detail", {})
    instance_id = detail.get("instance-id", "")
    state = detail.get("state", "")

    if not instance_id:
        logger.warning("No instance-id in event")
        return

    if state == "running":
        _handle_running(instance_id)
    elif state in ("terminated", "shutting-down", "stopped"):
        _handle_gone(instance_id)
    else:
        logger.info("Ignoring state=%s for %s", state, instance_id)


def _handle_running(instance_id):
    """Create mirror session for newly running instance if in business subnet."""
    try:
        resp = ec2.describe_instances(InstanceIds=[instance_id])
    except Exception as e:
        logger.error("Failed to describe %s: %s", instance_id, e)
        return

    for res in resp["Reservations"]:
        for inst in res["Instances"]:
            subnet_id = inst.get("SubnetId", "")
            if subnet_id not in BUSINESS_SUBNET_IDS:
                logger.info("Instance %s in subnet %s, not in business subnets, skipping",
                            instance_id, subnet_id)
                return

            if not inst.get("NetworkInterfaces"):
                logger.warning("Instance %s has no network interfaces yet, skipping", instance_id)
                return

            eni_id = inst["NetworkInterfaces"][0]["NetworkInterfaceId"]

            # Check if session already exists
            existing = ec2.describe_traffic_mirror_sessions(
                Filters=[{"Name": "network-interface-id", "Values": [eni_id]}]
            )["TrafficMirrorSessions"]

            if existing:
                logger.info("Mirror session already exists for ENI %s, skipping", eni_id)
                return

            # Find available session number
            used = {s["SessionNumber"] for s in existing}
            session_num = 1
            while session_num in used:
                session_num += 1

            result = ec2.create_traffic_mirror_session(
                NetworkInterfaceId=eni_id,
                TrafficMirrorTargetId=MIRROR_TARGET_ID,
                TrafficMirrorFilterId=MIRROR_FILTER_ID,
                SessionNumber=session_num,
                VirtualNetworkId=MIRROR_VNI,
                PacketLength=128,
                TagSpecifications=[{
                    "ResourceType": "traffic-mirror-session",
                    "Tags": [
                        {"Key": "Project", "Value": PROJECT_TAG},
                        {"Key": "ManagedBy", "Value": MANAGED_TAG},
                        {"Key": "SourceInstance", "Value": instance_id},
                    ],
                }],
            )
            sid = result["TrafficMirrorSession"]["TrafficMirrorSessionId"]
            logger.info("CREATED mirror session %s for instance %s (ENI %s)",
                        sid, instance_id, eni_id)


def _handle_gone(instance_id):
    """Delete mirror sessions tagged with this instance ID."""
    sessions = ec2.describe_traffic_mirror_sessions(
        Filters=[
            {"Name": "tag:ManagedBy", "Values": [MANAGED_TAG]},
            {"Name": "tag:SourceInstance", "Values": [instance_id]},
        ]
    )["TrafficMirrorSessions"]

    for session in sessions:
        sid = session["TrafficMirrorSessionId"]
        try:
            ec2.delete_traffic_mirror_session(TrafficMirrorSessionId=sid)
            logger.info("DELETED mirror session %s for terminated instance %s", sid, instance_id)
        except Exception as e:
            logger.error("Failed to delete session %s: %s", sid, e)
