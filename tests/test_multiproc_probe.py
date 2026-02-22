"""Tests for multiproc_probe.py — coordinator, worker logic, and sampling."""

import multiprocessing
import os
import queue
import socket
import struct
import sys
import time

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "probe"))

from multiproc_probe import (
    Coordinator,
    FlowKey,
    REPORT_INTERVAL,
    parse_vxlan_packet,
)


def _build_vxlan_packet(
    src_ip: str = "10.0.1.1",
    dst_ip: str = "10.0.2.2",
    proto: int = 6,
    src_port: int = 12345,
    dst_port: int = 80,
    ip_total_length: int = 60,
) -> bytes:
    vxlan = struct.pack("!II", 0x08000000, 12345 << 8)
    eth = b"\x00" * 12 + struct.pack("!H", 0x0800)
    ihl_ver = (4 << 4) | 5
    ip_hdr = struct.pack(
        "!BBHHHBBH4s4s",
        ihl_ver, 0, ip_total_length, 0, 0, 64, proto, 0,
        socket.inet_aton(src_ip), socket.inet_aton(dst_ip),
    )
    transport = struct.pack("!HH", src_port, dst_port) + b"\x00" * 16 if proto in (6, 17) else b"\x00" * 20
    return vxlan + eth + ip_hdr + transport


class TestCoordinatorDrainQueues:
    def test_merge_single_queue(self):
        coord = Coordinator(num_workers=1, sample_rate=1.0)
        q = multiprocessing.Queue()
        coord._queues = [q]

        flow1: FlowKey = ("10.0.1.1", "10.0.2.2", 6, 1234, 80)
        flow2: FlowKey = ("10.0.1.1", "10.0.2.3", 17, 53, 1024)
        q.put({flow1: [10, 1000], flow2: [5, 500]})
        time.sleep(0.05)  # Let Queue background thread flush

        merged = coord._drain_queues()
        assert merged[flow1] == [10, 1000]
        assert merged[flow2] == [5, 500]

    def test_merge_multiple_queues(self):
        coord = Coordinator(num_workers=2, sample_rate=1.0)
        q1 = multiprocessing.Queue()
        q2 = multiprocessing.Queue()
        coord._queues = [q1, q2]

        flow: FlowKey = ("10.0.1.1", "10.0.2.2", 6, 1234, 80)
        q1.put({flow: [10, 1000]})
        q2.put({flow: [20, 2000]})
        time.sleep(0.05)

        merged = coord._drain_queues()
        assert merged[flow] == [30, 3000]

    def test_drain_empty_queues(self):
        coord = Coordinator(num_workers=2, sample_rate=1.0)
        q1 = multiprocessing.Queue()
        q2 = multiprocessing.Queue()
        coord._queues = [q1, q2]

        merged = coord._drain_queues()
        assert merged == {}

    def test_drain_multiple_snapshots(self):
        coord = Coordinator(num_workers=1, sample_rate=1.0)
        q = multiprocessing.Queue()
        coord._queues = [q]

        flow: FlowKey = ("10.0.1.1", "10.0.2.2", 6, 1234, 80)
        q.put({flow: [5, 500]})
        q.put({flow: [10, 1000]})
        time.sleep(0.05)

        merged = coord._drain_queues()
        assert merged[flow] == [15, 1500]


class TestCoordinatorReport:
    def test_report_with_sampling_scale(self):
        coord = Coordinator(num_workers=1, sample_rate=0.5)
        q = multiprocessing.Queue()
        coord._queues = [q]

        flow: FlowKey = ("10.0.1.1", "10.0.2.2", 6, 1234, 80)
        flows = {flow: [100, 10000]}

        # _report should scale by 1/0.5 = 2x
        coord._report(flows)
        # After report, the flows dict is mutated
        assert flows[flow] == [200, 20000]

    def test_report_no_scale_at_rate_1(self):
        coord = Coordinator(num_workers=1, sample_rate=1.0)
        flow: FlowKey = ("10.0.1.1", "10.0.2.2", 6, 1234, 80)
        flows = {flow: [100, 10000]}
        coord._report(flows)
        assert flows[flow] == [100, 10000]

    def test_report_empty_flows(self):
        coord = Coordinator(num_workers=1, sample_rate=1.0)
        coord._report({})  # Should not raise


class TestSamplingDeterminism:
    def test_same_key_same_decision(self):
        """Same flow key should always produce the same sampling decision."""
        key: FlowKey = ("10.0.1.1", "10.0.2.2", 6, 12345, 80)
        sample_threshold = int(0.5 * 10000)
        decision = hash(key) % 10000 < sample_threshold
        # Run 100 times - should always be the same
        for _ in range(100):
            assert (hash(key) % 10000 < sample_threshold) == decision

    def test_different_keys_distributed(self):
        """With 50% sampling, roughly half of diverse keys should be sampled."""
        sample_threshold = int(0.5 * 10000)
        sampled = 0
        total = 1000
        for i in range(total):
            key: FlowKey = (f"10.0.{i // 256}.{i % 256}", "10.0.2.2", 6, i + 1024, 80)
            if hash(key) % 10000 < sample_threshold:
                sampled += 1
        # Should be roughly 50% (allow 35%-65% range)
        assert 350 < sampled < 650, f"Sampled {sampled}/{total} — expected ~500"


class TestCoordinatorStopIdempotent:
    def test_double_stop_safe(self):
        coord = Coordinator(num_workers=1, sample_rate=1.0)
        coord._stop_event.set()
        # Second stop should be a no-op
        coord.stop()
        coord.stop()
