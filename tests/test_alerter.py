"""Tests for alerter.py — dual-alert (fast + detail) logic."""

import os
import sys
import time
from unittest.mock import patch, MagicMock

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "probe"))

from alerter import FlowAlerter, bps_to_human, pps_to_human, bytes_to_human


@pytest.fixture
def alerter():
    """Alerter with low thresholds for easy triggering, no real notifications."""
    with patch.dict(os.environ, {
        "ALERT_THRESHOLD_BPS": "1000",   # 1 Kbps
        "ALERT_THRESHOLD_PPS": "100",    # 100 pps
        "ALERT_COOLDOWN_SEC": "300",
        "SNS_TOPIC_ARN": "",
        "SLACK_WEBHOOK_URL": "",
    }):
        yield FlowAlerter()


class TestCheckFast:
    def test_below_threshold_no_alert(self, alerter):
        assert alerter.check_fast(total_bytes=10, total_packets=5, interval_sec=1.0) is False

    def test_above_bps_threshold_triggers(self, alerter):
        # 2000 bytes * 8 / 1s = 16000 bps > 1000 bps threshold
        assert alerter.check_fast(total_bytes=2000, total_packets=5, interval_sec=1.0) is True

    def test_above_pps_threshold_triggers(self, alerter):
        # 200 packets / 1s = 200 pps > 100 pps threshold
        assert alerter.check_fast(total_bytes=10, total_packets=200, interval_sec=1.0) is True

    def test_zero_interval_no_alert(self, alerter):
        assert alerter.check_fast(total_bytes=99999, total_packets=99999, interval_sec=0) is False

    def test_cooldown_suppresses_second_fast(self, alerter):
        assert alerter.check_fast(total_bytes=2000, total_packets=5, interval_sec=1.0) is True
        assert alerter.check_fast(total_bytes=2000, total_packets=5, interval_sec=1.0) is False

    def test_sets_pending_detail(self, alerter):
        assert alerter._pending_detail is False
        alerter.check_fast(total_bytes=2000, total_packets=5, interval_sec=1.0)
        assert alerter._pending_detail is True


class TestCheckDetail:
    def _top_data(self):
        return (
            [{"ip": "10.0.1.1", "bytes": 5000, "info": {"name": "web-1"}}],
            [{"ip": "10.0.2.2", "bytes": 5000, "info": {"name": "db-1"}}],
            [{"key": ("10.0.1.1", "10.0.2.2", 6, 80, 3456), "bytes": 5000}],
        )

    def test_follow_up_after_fast_alert(self, alerter):
        src, dst, flows = self._top_data()
        # Fast alert fires
        alerter.check_fast(total_bytes=2000, total_packets=5, interval_sec=1.0)
        assert alerter._pending_detail is True
        # Detail follow-up fires (bypasses cooldown)
        result = alerter.check_detail(
            total_bytes=2000, total_packets=5, interval_sec=1.0,
            top_sources=src, top_dests=dst, top_flows=flows,
        )
        assert result is True
        assert alerter._pending_detail is False

    def test_no_follow_up_when_no_pending(self, alerter):
        src, dst, flows = self._top_data()
        # No fast alert fired, but threshold breached — cooldown blocks standalone
        alerter._last_alert_time = time.time()
        result = alerter.check_detail(
            total_bytes=2000, total_packets=5, interval_sec=1.0,
            top_sources=src, top_dests=dst, top_flows=flows,
        )
        assert result is False

    def test_standalone_detail_when_no_fast(self, alerter):
        src, dst, flows = self._top_data()
        # No fast alert, no cooldown — standalone detail fires
        result = alerter.check_detail(
            total_bytes=2000, total_packets=5, interval_sec=1.0,
            top_sources=src, top_dests=dst, top_flows=flows,
        )
        assert result is True

    def test_clears_pending_when_not_breached(self, alerter):
        alerter._pending_detail = True
        src, dst, flows = self._top_data()
        # Traffic dropped below threshold before detail report
        result = alerter.check_detail(
            total_bytes=1, total_packets=1, interval_sec=1.0,
            top_sources=src, top_dests=dst, top_flows=flows,
        )
        assert result is False
        assert alerter._pending_detail is False

    def test_below_threshold_no_alert(self, alerter):
        src, dst, flows = self._top_data()
        result = alerter.check_detail(
            total_bytes=10, total_packets=5, interval_sec=1.0,
            top_sources=src, top_dests=dst, top_flows=flows,
        )
        assert result is False


class TestDualAlertSequence:
    """End-to-end: fast alert at 1.5s, detail follow-up at 5s."""

    def test_full_sequence(self, alerter):
        src, dst, flows = (
            [{"ip": "10.0.1.1", "bytes": 5000, "info": {}}],
            [{"ip": "10.0.2.2", "bytes": 5000, "info": {}}],
            [{"key": ("10.0.1.1", "10.0.2.2", 6, 80, 3456), "bytes": 5000}],
        )

        # T=1.5s: fast alert fires
        assert alerter.check_fast(total_bytes=2000, total_packets=5, interval_sec=1.5) is True
        assert alerter._pending_detail is True

        # T=2.0s: another fast check — suppressed by cooldown
        assert alerter.check_fast(total_bytes=3000, total_packets=10, interval_sec=2.0) is False

        # T=5.0s: detail follow-up fires with Top-N
        assert alerter.check_detail(
            total_bytes=5000, total_packets=20, interval_sec=5.0,
            top_sources=src, top_dests=dst, top_flows=flows,
        ) is True
        assert alerter._pending_detail is False

        # T=10.0s: next detail — suppressed by cooldown (standalone path)
        assert alerter.check_detail(
            total_bytes=5000, total_packets=20, interval_sec=5.0,
            top_sources=src, top_dests=dst, top_flows=flows,
        ) is False


@pytest.fixture
def host_alerter():
    """Alerter with per-host thresholds enabled."""
    with patch.dict(os.environ, {
        "ALERT_THRESHOLD_BPS": "1000000",
        "ALERT_THRESHOLD_PPS": "100000",
        "ALERT_HOST_BPS": "1000",    # 1 Kbps per host
        "ALERT_HOST_PPS": "100",     # 100 pps per host
        "ALERT_COOLDOWN_SEC": "300",
        "SNS_TOPIC_ARN": "",
        "SLACK_WEBHOOK_URL": "",
    }):
        yield FlowAlerter()


class TestCheckHost:
    def test_single_ip_above_bps_threshold(self, host_alerter):
        # 2000 bytes * 8 / 1s = 16000 bps > 1000 bps
        src_agg = {"10.0.1.1": [10, 2000]}
        dst_agg = {}
        alerted = host_alerter.check_host(src_agg, dst_agg, 1.0, {})
        assert alerted == ["10.0.1.1"]

    def test_single_ip_above_pps_threshold(self, host_alerter):
        # 200 pps > 100 pps
        src_agg = {"10.0.1.1": [200, 10]}
        dst_agg = {}
        alerted = host_alerter.check_host(src_agg, dst_agg, 1.0, {})
        assert alerted == ["10.0.1.1"]

    def test_below_threshold_no_alert(self, host_alerter):
        src_agg = {"10.0.1.1": [5, 10]}
        dst_agg = {}
        alerted = host_alerter.check_host(src_agg, dst_agg, 1.0, {})
        assert alerted == []

    def test_disabled_when_threshold_zero(self, alerter):
        # Default alerter has ALERT_HOST_BPS=0
        src_agg = {"10.0.1.1": [999999, 999999]}
        alerted = alerter.check_host(src_agg, {}, 1.0, {})
        assert alerted == []

    def test_per_ip_independent_cooldown(self, host_alerter):
        src_agg = {"10.0.1.1": [10, 2000], "10.0.1.2": [10, 2000]}
        # First call: both alert
        alerted = host_alerter.check_host(src_agg, {}, 1.0, {})
        assert "10.0.1.1" in alerted
        assert "10.0.1.2" in alerted
        # Second call: both suppressed by cooldown
        alerted = host_alerter.check_host(src_agg, {}, 1.0, {})
        assert alerted == []

    def test_cooldown_only_affects_same_ip(self, host_alerter):
        # Host A alerts
        alerted = host_alerter.check_host({"10.0.1.1": [10, 2000]}, {}, 1.0, {})
        assert alerted == ["10.0.1.1"]
        # Host B still alerts (independent cooldown)
        alerted = host_alerter.check_host({"10.0.1.2": [10, 2000]}, {}, 1.0, {})
        assert alerted == ["10.0.1.2"]

    def test_dst_overrides_src_when_larger(self, host_alerter):
        src_agg = {"10.0.1.1": [5, 500]}    # below threshold
        dst_agg = {"10.0.1.1": [10, 2000]}  # above threshold
        alerted = host_alerter.check_host(src_agg, dst_agg, 1.0, {})
        assert alerted == ["10.0.1.1"]

    def test_src_kept_when_larger_than_dst(self, host_alerter):
        src_agg = {"10.0.1.1": [10, 2000]}  # above threshold
        dst_agg = {"10.0.1.1": [5, 500]}    # below, but src wins
        alerted = host_alerter.check_host(src_agg, dst_agg, 1.0, {})
        assert alerted == ["10.0.1.1"]

    def test_enriched_info_used(self, host_alerter):
        src_agg = {"10.0.1.1": [10, 2000]}
        enriched = {"10.0.1.1": {"name": "web-prod", "instance_id": "i-abc"}}
        alerted = host_alerter.check_host(src_agg, {}, 1.0, enriched)
        assert alerted == ["10.0.1.1"]

    def test_zero_interval_no_alert(self, host_alerter):
        src_agg = {"10.0.1.1": [999, 99999]}
        alerted = host_alerter.check_host(src_agg, {}, 0, {})
        assert alerted == []


class TestHumanFormatters:
    def test_bps_to_human(self):
        assert bps_to_human(500) == "500.0 bps"
        assert bps_to_human(1500) == "1.5 Kbps"
        assert bps_to_human(1_500_000_000) == "1.5 Gbps"

    def test_pps_to_human(self):
        assert pps_to_human(500) == "500.0 pps"
        assert pps_to_human(1500) == "1.5 Kpps"

    def test_bytes_to_human(self):
        assert bytes_to_human(512) == "512.0 B"
        assert bytes_to_human(1536) == "1.5 KB"
