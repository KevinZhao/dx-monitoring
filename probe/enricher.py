import logging
import os
import threading
import time
from typing import Optional

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)


class IPEnricher:
    def __init__(self):
        self._region = os.environ.get("AWS_REGION", "us-east-1")
        self._vpc_id = os.environ.get("VPC_ID", "")
        self._cache: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._running = False
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self._running = True
        self._refresh()
        self._thread = threading.Thread(target=self._refresh_loop, daemon=True)
        self._thread.start()
        logger.info("IPEnricher started (region=%s, vpc=%s)", self._region, self._vpc_id)

    def stop(self) -> None:
        self._running = False

    def _refresh_loop(self) -> None:
        while self._running:
            time.sleep(60)
            if self._running:
                self._refresh()

    def _refresh(self) -> None:
        try:
            ec2 = boto3.client("ec2", region_name=self._region)
            filters = []
            if self._vpc_id:
                filters.append({"Name": "vpc-id", "Values": [self._vpc_id]})

            paginator = ec2.get_paginator("describe_instances")
            new_cache: dict[str, dict] = {}

            for page in paginator.paginate(Filters=filters):
                for reservation in page["Reservations"]:
                    for instance in reservation["Instances"]:
                        instance_id = instance["InstanceId"]
                        tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
                        name = tags.get("Name", "")
                        asg = tags.get("aws:autoscaling:groupName", "")
                        owner = tags.get("Owner", "")

                        for nic in instance.get("NetworkInterfaces", []):
                            for addr in nic.get("PrivateIpAddresses", []):
                                ip = addr.get("PrivateIpAddress")
                                if ip:
                                    new_cache[ip] = {
                                        "instance_id": instance_id,
                                        "name": name,
                                        "asg": asg,
                                        "owner": owner,
                                    }

            with self._lock:
                self._cache = new_cache
            logger.info("IPEnricher refreshed: %d IPs cached", len(new_cache))

        except (ClientError, Exception) as e:
            logger.warning("IPEnricher refresh failed, keeping stale cache: %s", e)

    def enrich(self, ip: str) -> dict:
        with self._lock:
            info = self._cache.get(ip)
        if info:
            return {"ip": ip, **info}
        return {"ip": ip}

    def enrich_many(self, ips: list[str]) -> list[dict]:
        with self._lock:
            cache_snapshot = dict(self._cache)
        results = []
        for ip in ips:
            info = cache_snapshot.get(ip)
            if info:
                results.append({"ip": ip, **info})
            else:
                results.append({"ip": ip})
        return results
