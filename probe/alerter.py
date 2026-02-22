import json
import logging
import os
import time
from typing import Optional

import boto3
import requests
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)


def bytes_to_human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def bps_to_human(bps: float) -> str:
    for unit in ("bps", "Kbps", "Mbps", "Gbps", "Tbps"):
        if abs(bps) < 1000:
            return f"{bps:.1f} {unit}"
        bps /= 1000
    return f"{bps:.1f} Pbps"


def pps_to_human(pps: float) -> str:
    for unit in ("pps", "Kpps", "Mpps"):
        if abs(pps) < 1000:
            return f"{pps:.1f} {unit}"
        pps /= 1000
    return f"{pps:.1f} Gpps"


class FlowAlerter:
    def __init__(self):
        self._sns_topic_arn = os.environ.get("SNS_TOPIC_ARN", "")
        self._slack_webhook_url = os.environ.get("SLACK_WEBHOOK_URL", "")
        self._threshold_bps = float(os.environ.get("ALERT_THRESHOLD_BPS", "1000000000"))  # 1 Gbps
        self._threshold_pps = float(os.environ.get("ALERT_THRESHOLD_PPS", "1000000"))  # 1 Mpps
        self._cooldown_sec = float(os.environ.get("ALERT_COOLDOWN_SEC", "300"))
        self._last_alert_time: float = 0
        self._region = os.environ.get("AWS_REGION", "us-east-1")

    def check(
        self,
        total_bytes: int,
        total_packets: int,
        interval_sec: float,
        top_sources: list[dict],
        top_dests: list[dict],
        top_flows: list[dict],
    ) -> bool:
        if interval_sec <= 0:
            return False

        bps = total_bytes * 8 / interval_sec
        pps = total_packets / interval_sec

        if bps <= self._threshold_bps and pps <= self._threshold_pps:
            return False

        now = time.time()
        if now - self._last_alert_time < self._cooldown_sec:
            logger.debug("Alert suppressed by cooldown (%.0fs remaining)",
                         self._cooldown_sec - (now - self._last_alert_time))
            return False

        self._last_alert_time = now
        message = self._format_alert(bps, pps, top_sources[:5], top_dests[:5], top_flows[:5])
        subject = f"Traffic Alert: {bps_to_human(bps)} / {pps_to_human(pps)}"

        logger.warning("ALERT triggered: %s", subject)

        if self._sns_topic_arn:
            self._send_sns(message, subject)
        if self._slack_webhook_url:
            self._send_slack(message)

        return True

    def _format_alert(
        self,
        bps: float,
        pps: float,
        top_sources: list[dict],
        top_dests: list[dict],
        top_flows: list[dict],
    ) -> str:
        lines = [
            "=== VGW Traffic Mirror Alert ===",
            f"Rate: {bps_to_human(bps)} / {pps_to_human(pps)}",
            f"Threshold: {bps_to_human(self._threshold_bps)} / {pps_to_human(self._threshold_pps)}",
            "",
            "--- Top Sources ---",
        ]
        for s in top_sources:
            info = s.get("info", {})
            label = info.get("name") or info.get("instance_id") or s.get("ip", "?")
            lines.append(f"  {s.get('ip', '?'):>15s}  {bytes_to_human(s.get('bytes', 0)):>10s}  ({label})")

        lines.append("")
        lines.append("--- Top Destinations ---")
        for d in top_dests:
            info = d.get("info", {})
            label = info.get("name") or info.get("instance_id") or d.get("ip", "?")
            lines.append(f"  {d.get('ip', '?'):>15s}  {bytes_to_human(d.get('bytes', 0)):>10s}  ({label})")

        lines.append("")
        lines.append("--- Top Flows ---")
        for f in top_flows:
            key = f.get("key", ("?", "?", 0, 0, 0))
            lines.append(
                f"  {key[0]}:{key[3]} -> {key[1]}:{key[4]} proto={key[2]}  "
                f"{bytes_to_human(f.get('bytes', 0))}"
            )

        return "\n".join(lines)

    def _send_sns(self, message: str, subject: str) -> None:
        try:
            sns = boto3.client("sns", region_name=self._region)
            sns.publish(
                TopicArn=self._sns_topic_arn,
                Subject=subject[:100],
                Message=message,
            )
            logger.info("SNS alert sent to %s", self._sns_topic_arn)
        except ClientError as e:
            logger.error("Failed to send SNS alert: %s", e)

    def _send_slack(self, message: str) -> None:
        try:
            payload = {"text": f"```\n{message}\n```"}
            resp = requests.post(
                self._slack_webhook_url,
                json=payload,
                timeout=10,
            )
            resp.raise_for_status()
            logger.info("Slack alert sent")
        except requests.RequestException as e:
            logger.error("Failed to send Slack alert: %s", e)
