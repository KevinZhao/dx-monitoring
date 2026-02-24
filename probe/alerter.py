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


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        return float(raw)
    except (ValueError, TypeError):
        logger.error("Invalid %s='%s', using default %.0f", name, raw, default)
        return default


class FlowAlerter:
    def __init__(self):
        self._sns_topic_arn = os.environ.get("SNS_TOPIC_ARN", "")
        self._slack_webhook_url = os.environ.get("SLACK_WEBHOOK_URL", "")
        self._threshold_bps = _env_float("ALERT_THRESHOLD_BPS", 1e9)
        self._threshold_pps = _env_float("ALERT_THRESHOLD_PPS", 1e6)
        self._cooldown_sec = _env_float("ALERT_COOLDOWN_SEC", 300)
        self._last_alert_time: float = 0
        self._pending_detail = False  # fast alert fired, waiting for detail follow-up
        self._host_threshold_bps = _env_float("ALERT_HOST_BPS", 0)  # 0 = disabled
        self._host_threshold_pps = _env_float("ALERT_HOST_PPS", 0)
        self._host_cooldowns: dict[str, float] = {}  # ip -> last_alert_time
        self._region = os.environ.get("AWS_REGION", "us-east-1")
        self._sns_client = boto3.client("sns", region_name=self._region) if self._sns_topic_arn else None

    def check_fast(
        self,
        total_bytes: int,
        total_packets: int,
        interval_sec: float,
    ) -> bool:
        """Fast threshold check (called every 0.5s poll). Sends rate-only alert."""
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
        self._pending_detail = True

        subject = f"[FAST] Traffic Alert: {bps_to_human(bps)} / {pps_to_human(pps)}"
        message = (
            "=== VGW Traffic Mirror Alert (Fast) ===\n"
            f"Rate: {bps_to_human(bps)} / {pps_to_human(pps)}\n"
            f"Threshold: {bps_to_human(self._threshold_bps)} / {pps_to_human(self._threshold_pps)}\n"
            "\nTop Talker details will follow in ~5s."
        )

        logger.warning("FAST ALERT triggered: %s", subject)

        if self._sns_topic_arn:
            self._send_sns(message, subject)
        if self._slack_webhook_url:
            self._send_slack(message)

        return True

    def check_detail(
        self,
        total_bytes: int,
        total_packets: int,
        interval_sec: float,
        top_sources: list[dict],
        top_dests: list[dict],
        top_flows: list[dict],
    ) -> bool:
        """Detail check (called every 5s report). Sends Top-N follow-up if pending,
        or a full alert if threshold newly crossed."""
        if interval_sec <= 0:
            return False

        bps = total_bytes * 8 / interval_sec
        pps = total_packets / interval_sec

        breached = bps > self._threshold_bps or pps > self._threshold_pps

        if self._pending_detail and breached:
            # Follow-up to fast alert — always send (bypasses cooldown)
            self._pending_detail = False
            message = self._format_alert(bps, pps, top_sources[:5], top_dests[:5], top_flows[:5])
            subject = f"[DETAIL] Traffic Alert: {bps_to_human(bps)} / {pps_to_human(pps)}"

            logger.warning("DETAIL ALERT follow-up: %s", subject)

            if self._sns_topic_arn:
                self._send_sns(message, subject)
            if self._slack_webhook_url:
                self._send_slack(message)
            return True

        self._pending_detail = False

        if not breached:
            return False

        # No pending fast alert — standalone full alert (respects cooldown)
        now = time.time()
        if now - self._last_alert_time < self._cooldown_sec:
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

    def check_host(
        self,
        src_agg: dict[str, list[int]],
        dst_agg: dict[str, list[int]],
        interval_sec: float,
        enriched: dict[str, dict],
    ) -> list[str]:
        """Per-host threshold check. Returns list of alerted IPs."""
        if interval_sec <= 0:
            return []
        if self._host_threshold_bps <= 0 and self._host_threshold_pps <= 0:
            return []

        # Merge src and dst: per IP take the max-direction traffic
        all_ips: dict[str, tuple[int, int, str]] = {}  # ip -> (packets, bytes, direction)
        for ip, (pkts, byt) in src_agg.items():
            all_ips[ip] = (pkts, byt, "source")
        for ip, (pkts, byt) in dst_agg.items():
            prev = all_ips.get(ip)
            if prev is None or byt > prev[1]:
                all_ips[ip] = (pkts, byt, "destination")

        now = time.time()
        alerted: list[str] = []

        for ip, (pkts, byt, direction) in all_ips.items():
            bps = byt * 8 / interval_sec
            pps = pkts / interval_sec

            if self._host_threshold_bps > 0 and bps > self._host_threshold_bps:
                pass  # breached
            elif self._host_threshold_pps > 0 and pps > self._host_threshold_pps:
                pass  # breached
            else:
                continue

            last = self._host_cooldowns.get(ip, 0)
            if now - last < self._cooldown_sec:
                continue

            self._host_cooldowns[ip] = now
            alerted.append(ip)

            info = enriched.get(ip, {})
            label = info.get("name") or info.get("instance_id") or ip
            subject = f"[HOST] Traffic Alert: {ip} ({label}) {bps_to_human(bps)}"
            message = (
                "=== VGW Per-Host Traffic Alert ===\n"
                f"Host: {ip} ({label})\n"
                f"Rate: {bps_to_human(bps)} / {pps_to_human(pps)}\n"
                f"Threshold: {bps_to_human(self._host_threshold_bps)} / {pps_to_human(self._host_threshold_pps)}\n"
                f"Direction: {direction}"
            )

            logger.warning("HOST ALERT: %s", subject)

            if self._sns_topic_arn:
                self._send_sns(message, subject)
            if self._slack_webhook_url:
                self._send_slack(message)

        return alerted

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
            self._sns_client.publish(
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
