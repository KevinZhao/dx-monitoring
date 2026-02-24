#!/usr/bin/env python3
"""Multi-process VXLAN probe with SO_REUSEPORT kernel load balancing."""

import ctypes
import logging
import multiprocessing
import os
import queue
import signal
import socket
import struct
import sys
import time
from collections import defaultdict
from typing import Optional

# Ensure probe directory is on sys.path for enricher/alerter imports
_probe_dir = os.path.dirname(os.path.abspath(__file__))
if _probe_dir not in sys.path:
    sys.path.insert(0, _probe_dir)

from enricher import IPEnricher
from alerter import FlowAlerter

logger = logging.getLogger("multiproc_probe")

# ---------------------------------------------------------------------------
# Protocol constants
# ---------------------------------------------------------------------------
ETHERTYPE_IPV4 = 0x0800
PROTO_TCP = 6
PROTO_UDP = 17
VXLAN_HDR_LEN = 8
ETH_HDR_LEN = 14
IP_HDR_MIN_LEN = 20

FlowKey = tuple[str, str, int, int, int]  # src_ip, dst_ip, proto, src_port, dst_port

REPORT_INTERVAL = 5.0  # seconds — full report with Top-N
CAP_FLUSH_INTERVAL = 1.0  # seconds — worker flush cycle (controls detection latency)
COORDINATOR_POLL = 0.5  # seconds — coordinator queue poll interval
BIND_ADDR = "0.0.0.0"
BIND_PORT = 4789
RCVBUF_SIZE = 128 * 1024 * 1024  # 128 MB

# ---------------------------------------------------------------------------
# Try to load C libraries
# ---------------------------------------------------------------------------
_fast_recv_lib = None  # fast_recv.so: recvmmsg + parse + aggregate (preferred)


class _CFlowRecord(ctypes.Structure):
    """Matches struct flow_record in fast_recv.c (32 bytes)."""
    _fields_ = [
        ("src_ip", ctypes.c_uint32),
        ("dst_ip", ctypes.c_uint32),
        ("src_port", ctypes.c_uint16),
        ("dst_port", ctypes.c_uint16),
        ("proto", ctypes.c_uint8),
        ("_pad1", ctypes.c_uint8),
        ("_pad2", ctypes.c_uint16),
        ("packets", ctypes.c_uint64),
        ("bytes", ctypes.c_uint64),
    ]


class _CFlowResult(ctypes.Structure):
    """Matches struct flow_result in fast_parse.c."""
    _fields_ = [
        ("src_ip", ctypes.c_uint32),
        ("dst_ip", ctypes.c_uint32),
        ("protocol", ctypes.c_uint8),
        ("_pad1", ctypes.c_uint8),
        ("src_port", ctypes.c_uint16),
        ("dst_port", ctypes.c_uint16),
        ("pkt_len", ctypes.c_uint16),
    ]


def _load_fast_recv():
    global _fast_recv_lib
    so_path = os.path.join(_probe_dir, "fast_recv.so")
    if not os.path.isfile(so_path):
        return
    try:
        lib = ctypes.CDLL(so_path)
        lib.cap_create.argtypes = [ctypes.c_int, ctypes.c_int]
        lib.cap_create.restype = ctypes.c_void_p
        lib.cap_get_rcvbuf.argtypes = [ctypes.c_void_p]
        lib.cap_get_rcvbuf.restype = ctypes.c_int
        lib.cap_run.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.cap_run.restype = ctypes.c_int
        lib.cap_stop.argtypes = [ctypes.c_void_p]
        lib.cap_stop.restype = None
        lib.cap_flush.argtypes = [ctypes.c_void_p]
        lib.cap_flush.restype = ctypes.c_int
        lib.cap_get_flush_buf.argtypes = [ctypes.c_void_p]
        lib.cap_get_flush_buf.restype = ctypes.POINTER(_CFlowRecord)
        lib.cap_get_total_pkts.argtypes = [ctypes.c_void_p]
        lib.cap_get_total_pkts.restype = ctypes.c_uint64
        lib.cap_get_total_parsed.argtypes = [ctypes.c_void_p]
        lib.cap_get_total_parsed.restype = ctypes.c_uint64
        lib.cap_destroy.argtypes = [ctypes.c_void_p]
        lib.cap_destroy.restype = None
        lib.ip_to_str.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_int]
        lib.ip_to_str.restype = None
        lib.cap_get_dropped_flows.argtypes = [ctypes.c_void_p]
        lib.cap_get_dropped_flows.restype = ctypes.c_uint64
        lib.cap_get_probe_failures.argtypes = [ctypes.c_void_p]
        lib.cap_get_probe_failures.restype = ctypes.c_uint64
        _fast_recv_lib = lib
        logger.info("Loaded fast_recv.so from %s", so_path)
    except OSError as e:
        logger.warning("Failed to load fast_recv.so: %s – using Python recv loop", e)


def parse_vxlan_packet(data: bytes) -> Optional[tuple[FlowKey, int]]:
    """Parse VXLAN-encapsulated packet, return (flow_key, inner_pkt_len) or None."""
    offset = 0
    remaining = len(data)

    # VXLAN header (8 bytes)
    if remaining < VXLAN_HDR_LEN:
        return None
    offset += VXLAN_HDR_LEN
    remaining -= VXLAN_HDR_LEN

    # Ethernet header (14 bytes): dst_mac(6) + src_mac(6) + ethertype(2)
    if remaining < ETH_HDR_LEN:
        return None
    ethertype = struct.unpack_from("!H", data, offset + 12)[0]
    offset += ETH_HDR_LEN
    remaining -= ETH_HDR_LEN

    if ethertype != ETHERTYPE_IPV4:
        return None

    # IP header
    if remaining < IP_HDR_MIN_LEN:
        return None

    version_ihl = data[offset]
    ihl = (version_ihl & 0x0F) * 4
    if ihl < IP_HDR_MIN_LEN or remaining < ihl:
        return None

    total_length = struct.unpack_from("!H", data, offset + 2)[0]
    protocol = data[offset + 9]
    src_ip_bytes = data[offset + 12 : offset + 16]
    dst_ip_bytes = data[offset + 16 : offset + 20]

    src_ip = socket.inet_ntoa(src_ip_bytes)
    dst_ip = socket.inet_ntoa(dst_ip_bytes)
    pkt_len = total_length

    src_port = 0
    dst_port = 0

    # Parse TCP/UDP ports
    if protocol in (PROTO_TCP, PROTO_UDP):
        transport_offset = offset + ihl
        if len(data) >= transport_offset + 4:
            src_port, dst_port = struct.unpack_from("!HH", data, transport_offset)

    return (src_ip, dst_ip, protocol, src_port, dst_port), pkt_len


# ---------------------------------------------------------------------------
# Worker process — C fast path (recvmmsg + parse + aggregate in C)
# ---------------------------------------------------------------------------

def _worker_c(
    worker_idx: int,
    result_queue: multiprocessing.Queue,
    stop_event: multiprocessing.Event,
    sample_rate: float,
):
    """Worker using fast_recv.so: recvmmsg batch capture + C hash-table aggregation."""
    log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
        force=True,
    )
    wlog = logging.getLogger(f"worker-{worker_idx}")
    wlog.info("Worker-%d started (pid=%d) [C fast_recv]", worker_idx, os.getpid())
    signal.signal(signal.SIGINT, signal.SIG_IGN)

    lib = _fast_recv_lib
    ctx = lib.cap_create(BIND_PORT, RCVBUF_SIZE)
    if not ctx:
        wlog.error("Worker-%d: cap_create failed", worker_idx)
        return

    rcvbuf = lib.cap_get_rcvbuf(ctx)
    wlog.info("Worker-%d socket SO_RCVBUF=%d", worker_idx, rcvbuf)

    ip_buf = ctypes.create_string_buffer(16)
    duration_ms = int(CAP_FLUSH_INTERVAL * 1000)
    inv_rate = 1.0 / sample_rate if sample_rate < 1.0 else 1.0
    cumulative_queue_drops = 0

    try:
        while not stop_event.is_set():
            # Capture for CAP_FLUSH_INTERVAL seconds (C does recvmmsg + parse + aggregate)
            total_pkts = lib.cap_run(ctx, duration_ms)

            # Flush C hash table → flow_record array
            count = lib.cap_flush(ctx)

            # Report drop stats periodically (every flush cycle)
            dropped = lib.cap_get_dropped_flows(ctx)
            probe_fail = lib.cap_get_probe_failures(ctx)
            if dropped > 0 or probe_fail > 0:
                wlog.warning(
                    "Worker-%d DROP STATS: flow_table_full=%d probe_collisions=%d queue_drops=%d",
                    worker_idx, dropped, probe_fail, cumulative_queue_drops,
                )

            if count == 0:
                continue

            parsed = lib.cap_get_total_parsed(ctx)
            wlog.debug("Worker-%d: recv=%d parsed=%d flows=%d", worker_idx, total_pkts, parsed, count)

            buf = lib.cap_get_flush_buf(ctx)
            flows: dict = {}
            for i in range(count):
                r = buf[i]
                lib.ip_to_str(r.src_ip, ip_buf, 16)
                src = ip_buf.value.decode()
                lib.ip_to_str(r.dst_ip, ip_buf, 16)
                dst = ip_buf.value.decode()
                pkts = int(r.packets)
                byt = int(r.bytes)
                if inv_rate != 1.0:
                    pkts = int(pkts * inv_rate)
                    byt = int(byt * inv_rate)
                flows[(src, dst, r.proto, r.src_port, r.dst_port)] = [pkts, byt]

            try:
                result_queue.put(flows, timeout=0.5)
            except queue.Full:
                cumulative_queue_drops += 1
                wlog.warning("Worker-%d queue full, dropping %d flows (total_drops=%d)",
                             worker_idx, count, cumulative_queue_drops)
    finally:
        lib.cap_destroy(ctx)
        wlog.info("Worker-%d exiting", worker_idx)


# ---------------------------------------------------------------------------
# Coordinator (runs in main process)
# ---------------------------------------------------------------------------

def _read_udp_drops() -> int:
    """Read total UDP socket drops from /proc/net/udp (column 12 = drops)."""
    total = 0
    try:
        with open("/proc/net/udp", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 13 and parts[0] != "sl":
                    try:
                        total += int(parts[12])
                    except (ValueError, IndexError):
                        pass
    except OSError:
        pass
    return total


class Coordinator:
    def __init__(self, num_workers: int, sample_rate: float):
        self._num_workers = num_workers
        self._sample_rate = sample_rate
        self._inv_rate = 1.0 / sample_rate if sample_rate > 0 else 1.0
        self._queues: list[multiprocessing.Queue] = []
        self._workers: list[multiprocessing.Process] = []
        self._stop_event = multiprocessing.Event()
        self._enricher = IPEnricher()
        self._alerter = FlowAlerter()
        self._last_udp_drops = 0

    def start(self) -> None:
        logger.info(
            "Coordinator starting: %d workers, sample_rate=%.4f",
            self._num_workers,
            self._sample_rate,
        )
        self._enricher.start()

        if not _fast_recv_lib:
            logger.error("fast_recv.so not found — compile with: gcc -O2 -shared -fPIC -o fast_recv.so fast_recv.c")
            sys.exit(1)
        worker_fn = _worker_c

        for i in range(self._num_workers):
            q: multiprocessing.Queue = multiprocessing.Queue()
            self._queues.append(q)
            p = multiprocessing.Process(
                target=worker_fn,
                args=(i, q, self._stop_event, self._sample_rate),
                daemon=True,
            )
            p.start()
            self._workers.append(p)
            logger.info("Launched worker-%d (pid=%d)", i, p.pid)

        # Main loop: merge + report every REPORT_INTERVAL
        try:
            self._run_loop()
        except KeyboardInterrupt:
            pass
        finally:
            self.stop()

    def stop(self) -> None:
        if self._stop_event.is_set():
            return
        logger.info("Coordinator stopping...")
        self._stop_event.set()

        # Drain queues first to unblock workers stuck on queue.put()
        time.sleep(0.5)
        merged = self._drain_queues()

        for p in self._workers:
            p.join(timeout=3)
            if p.is_alive():
                logger.warning("Worker pid=%d did not exit, terminating", p.pid)
                p.terminate()

        # Final drain after workers exit
        final = self._drain_queues()
        for key, counters in final.items():
            entry = merged.setdefault(key, [0, 0])
            entry[0] += counters[0]
            entry[1] += counters[1]

        if merged:
            self._report(merged)

        self._enricher.stop()
        logger.info("Coordinator stopped")

    def _run_loop(self) -> None:
        accumulated: dict[FlowKey, list[int]] = defaultdict(lambda: [0, 0])
        last_report = time.monotonic()

        while not self._stop_event.is_set():
            time.sleep(COORDINATOR_POLL)

            # Drain worker queues into accumulator
            fresh = self._drain_queues()
            if fresh:
                for key, counters in fresh.items():
                    entry = accumulated[key]
                    entry[0] += counters[0]
                    entry[1] += counters[1]

                # Quick alert check on every poll (low-latency detection)
                now = time.monotonic()
                accum_interval = now - last_report
                if accum_interval > 0:
                    total_bytes = sum(v[1] for v in accumulated.values())
                    total_packets = sum(v[0] for v in accumulated.values())
                    self._alerter.check_fast(
                        total_bytes=total_bytes,
                        total_packets=total_packets,
                        interval_sec=accum_interval,
                    )

            # Full report with Top-N every REPORT_INTERVAL
            now = time.monotonic()
            if now - last_report >= REPORT_INTERVAL:
                if accumulated:
                    self._report(dict(accumulated), now - last_report)
                accumulated = defaultdict(lambda: [0, 0])
                last_report = now

    def _drain_queues(self) -> dict[FlowKey, list[int]]:
        merged: dict[FlowKey, list[int]] = defaultdict(lambda: [0, 0])
        for q in self._queues:
            while True:
                try:
                    snapshot = q.get_nowait()
                except queue.Empty:
                    break
                for key, counters in snapshot.items():
                    entry = merged[key]
                    entry[0] += counters[0]
                    entry[1] += counters[1]
        return dict(merged)

    def _report(self, flows: dict[FlowKey, list[int]], interval: float = REPORT_INTERVAL) -> None:
        if not flows:
            return

        # Scale counters if sampling is active
        inv = self._inv_rate
        if inv != 1.0:
            for counters in flows.values():
                counters[0] = int(counters[0] * inv)
                counters[1] = int(counters[1] * inv)

        total_bytes = sum(v[1] for v in flows.values())
        total_packets = sum(v[0] for v in flows.values())

        # Top-10 flows by bytes
        sorted_flows = sorted(flows.items(), key=lambda x: x[1][1], reverse=True)
        top_flows = [{"key": k, "packets": v[0], "bytes": v[1]} for k, v in sorted_flows[:10]]

        # Aggregate by src_ip, dst_ip — [packets, bytes]
        src_agg: dict[str, list[int]] = defaultdict(lambda: [0, 0])
        dst_agg: dict[str, list[int]] = defaultdict(lambda: [0, 0])
        for (src_ip, dst_ip, _, _, _), counters in flows.items():
            s = src_agg[src_ip]
            s[0] += counters[0]; s[1] += counters[1]
            d = dst_agg[dst_ip]
            d[0] += counters[0]; d[1] += counters[1]

        top_src = sorted(src_agg.items(), key=lambda x: x[1][1], reverse=True)[:10]
        top_dst = sorted(dst_agg.items(), key=lambda x: x[1][1], reverse=True)[:10]

        # Enrich IPs (top-10 + any host-alert candidates)
        all_ips = list({ip for ip, _ in top_src} | {ip for ip, _ in top_dst})
        enriched = {e["ip"]: e for e in self._enricher.enrich_many(all_ips)}

        top_sources = [{"ip": ip, "bytes": v[1], "info": enriched.get(ip, {})} for ip, v in top_src]
        top_dests = [{"ip": ip, "bytes": v[1], "info": enriched.get(ip, {})} for ip, v in top_dst]

        logger.info(
            "Report: %d flows, %d packets, %d bytes | top_src=%s top_dst=%s",
            len(flows),
            total_packets,
            total_bytes,
            [(ip, v[1]) for ip, v in top_src[:3]],
            [(ip, v[1]) for ip, v in top_dst[:3]],
        )

        self._alerter.check_detail(
            total_bytes=total_bytes,
            total_packets=total_packets,
            interval_sec=interval,
            top_sources=top_sources,
            top_dests=top_dests,
            top_flows=top_flows,
        )

        self._alerter.check_host(
            src_agg=dict(src_agg),
            dst_agg=dict(dst_agg),
            interval_sec=interval,
            enriched=enriched,
        )

        # Monitor kernel-level UDP socket drops
        current_drops = _read_udp_drops()
        delta = current_drops - self._last_udp_drops
        if delta > 0:
            logger.warning(
                "KERNEL UDP DROPS detected: +%d since last report (total=%d)",
                delta, current_drops,
            )
        self._last_udp_drops = current_drops


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    _load_fast_recv()

    # Worker count: 0 or unset = auto-detect (vCPU count)
    try:
        num_workers = int(os.environ.get("PROBE_WORKERS", "0"))
    except (ValueError, TypeError):
        logger.error("Invalid PROBE_WORKERS, using auto-detect")
        num_workers = 0
    if num_workers <= 0:
        num_workers = os.cpu_count() or 1
    logger.info("Worker count: %d", num_workers)

    try:
        sample_rate = float(os.environ.get("PROBE_SAMPLE_RATE", "1.0"))
    except (ValueError, TypeError):
        logger.error("Invalid PROBE_SAMPLE_RATE, using 1.0")
        sample_rate = 1.0
    sample_rate = max(0.0001, min(1.0, sample_rate))
    logger.info("Sample rate: %.4f", sample_rate)

    coordinator = Coordinator(num_workers=num_workers, sample_rate=sample_rate)

    def handle_signal(signum, frame):
        logger.info("Received signal %d, shutting down", signum)
        coordinator.stop()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    try:
        coordinator.start()
    except Exception:
        logger.exception("Fatal error in multiproc_probe")
        coordinator.stop()
        sys.exit(1)


if __name__ == "__main__":
    main()
