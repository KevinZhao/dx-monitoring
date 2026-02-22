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

REPORT_INTERVAL = 5.0  # seconds
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
    duration_ms = int(REPORT_INTERVAL * 1000)
    inv_rate = 1.0 / sample_rate if sample_rate < 1.0 else 1.0

    try:
        while not stop_event.is_set():
            # Capture for REPORT_INTERVAL seconds (C does recvmmsg + parse + aggregate)
            total_pkts = lib.cap_run(ctx, duration_ms)

            # Flush C hash table → flow_record array
            count = lib.cap_flush(ctx)
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
                result_queue.put(flows, timeout=2.0)
            except queue.Full:
                wlog.warning("Worker-%d queue full, dropping %d flows", worker_idx, count)
    finally:
        lib.cap_destroy(ctx)
        wlog.info("Worker-%d exiting", worker_idx)


# ---------------------------------------------------------------------------
# Worker process — Python fallback
# ---------------------------------------------------------------------------

def _worker_py(
    worker_idx: int,
    result_queue: multiprocessing.Queue,
    stop_event: multiprocessing.Event,
    sample_rate: float,
):
    """Fallback worker using Python socket.recvfrom()."""
    log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
        force=True,
    )
    wlog = logging.getLogger(f"worker-{worker_idx}")
    wlog.info("Worker-%d started (pid=%d) [Python fallback]", worker_idx, os.getpid())
    signal.signal(signal.SIGINT, signal.SIG_IGN)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, RCVBUF_SIZE)
    sock.settimeout(1.0)
    sock.bind((BIND_ADDR, BIND_PORT))

    actual_rcvbuf = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    wlog.info("Worker-%d socket bound to %s:%d (SO_RCVBUF=%d)", worker_idx, BIND_ADDR, BIND_PORT, actual_rcvbuf)

    parse = parse_vxlan_packet
    sampling = sample_rate < 1.0
    sample_threshold = int(sample_rate * 10000)

    flows: dict[FlowKey, list[int]] = defaultdict(lambda: [0, 0])
    last_flush = time.monotonic()

    try:
        while not stop_event.is_set():
            try:
                data, _ = sock.recvfrom(65535)
            except socket.timeout:
                now = time.monotonic()
                if now - last_flush >= REPORT_INTERVAL:
                    snapshot = dict(flows)
                    flows.clear()
                    last_flush = now
                    if snapshot:
                        try:
                            result_queue.put(snapshot, timeout=2.0)
                        except queue.Full:
                            wlog.warning("Worker-%d queue full", worker_idx)
                continue
            except OSError:
                if not stop_event.is_set():
                    wlog.exception("Socket error in worker-%d", worker_idx)
                break

            result = parse(data)
            if result is None:
                continue
            key, pkt_len = result

            if sampling and hash(key) % 10000 >= sample_threshold:
                continue

            entry = flows[key]
            entry[0] += 1
            entry[1] += pkt_len

            now = time.monotonic()
            if now - last_flush >= REPORT_INTERVAL:
                snapshot = dict(flows)
                flows.clear()
                last_flush = now
                if snapshot:
                    try:
                        result_queue.put(snapshot, timeout=2.0)
                    except queue.Full:
                        wlog.warning("Worker-%d queue full", worker_idx)
    finally:
        if flows:
            try:
                result_queue.put(dict(flows), timeout=1.0)
            except queue.Full:
                pass
        sock.close()
        wlog.info("Worker-%d exiting", worker_idx)


# ---------------------------------------------------------------------------
# Coordinator (runs in main process)
# ---------------------------------------------------------------------------

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

    def start(self) -> None:
        logger.info(
            "Coordinator starting: %d workers, sample_rate=%.4f",
            self._num_workers,
            self._sample_rate,
        )
        self._enricher.start()

        worker_fn = _worker_c if _fast_recv_lib else _worker_py
        logger.info("Worker function: %s", "C recvmmsg" if _fast_recv_lib else "Python fallback")

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

        for p in self._workers:
            p.join(timeout=5)
            if p.is_alive():
                logger.warning("Worker pid=%d did not exit, terminating", p.pid)
                p.terminate()

        # Allow workers' Queue feeder threads to flush final put()
        time.sleep(0.5)

        # Drain remaining items from queues
        merged = self._drain_queues()
        if merged:
            self._report(merged)

        self._enricher.stop()
        logger.info("Coordinator stopped")

    def _run_loop(self) -> None:
        while not self._stop_event.is_set():
            time.sleep(REPORT_INTERVAL)
            merged = self._drain_queues()
            if merged:
                self._report(merged)

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

    def _report(self, flows: dict[FlowKey, list[int]]) -> None:
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

        # Aggregate by src_ip, dst_ip
        src_agg: dict[str, int] = defaultdict(int)
        dst_agg: dict[str, int] = defaultdict(int)
        for (src_ip, dst_ip, _, _, _), counters in flows.items():
            src_agg[src_ip] += counters[1]
            dst_agg[dst_ip] += counters[1]

        top_src = sorted(src_agg.items(), key=lambda x: x[1], reverse=True)[:10]
        top_dst = sorted(dst_agg.items(), key=lambda x: x[1], reverse=True)[:10]

        # Enrich IPs
        all_ips = list({ip for ip, _ in top_src} | {ip for ip, _ in top_dst})
        enriched = {e["ip"]: e for e in self._enricher.enrich_many(all_ips)}

        top_sources = [{"ip": ip, "bytes": b, "info": enriched.get(ip, {})} for ip, b in top_src]
        top_dests = [{"ip": ip, "bytes": b, "info": enriched.get(ip, {})} for ip, b in top_dst]

        logger.info(
            "Report: %d flows, %d packets, %d bytes | top_src=%s top_dst=%s",
            len(flows),
            total_packets,
            total_bytes,
            top_src[:3],
            top_dst[:3],
        )

        self._alerter.check(
            total_bytes=total_bytes,
            total_packets=total_packets,
            interval_sec=REPORT_INTERVAL,
            top_sources=top_sources,
            top_dests=top_dests,
            top_flows=top_flows,
        )


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
    num_workers = int(os.environ.get("PROBE_WORKERS", "0"))
    if num_workers <= 0:
        num_workers = os.cpu_count() or 1
    logger.info("Worker count: %d", num_workers)

    sample_rate = float(os.environ.get("PROBE_SAMPLE_RATE", "1.0"))
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
