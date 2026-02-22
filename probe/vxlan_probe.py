#!/usr/bin/env python3
"""High-performance VXLAN packet capture and flow aggregation probe."""

import logging
import os
import signal
import socket
import struct
import sys
import threading
import time
from collections import defaultdict
from typing import Optional

from enricher import IPEnricher
from alerter import FlowAlerter

logger = logging.getLogger("vxlan_probe")

# Protocol constants
ETHERTYPE_IPV4 = 0x0800
PROTO_TCP = 6
PROTO_UDP = 17
VXLAN_HDR_LEN = 8
ETH_HDR_LEN = 14
IP_HDR_MIN_LEN = 20

FlowKey = tuple[str, str, int, int, int]  # src_ip, dst_ip, proto, src_port, dst_port


class FlowAggregator:
    def __init__(self):
        self._flows: dict[FlowKey, dict[str, int]] = defaultdict(lambda: {"packets": 0, "bytes": 0})
        self._lock = threading.Lock()

    def record(self, key: FlowKey, pkt_len: int) -> None:
        with self._lock:
            entry = self._flows[key]
            entry["packets"] += 1
            entry["bytes"] += pkt_len

    def flush(self) -> dict[FlowKey, dict[str, int]]:
        with self._lock:
            old = self._flows
            self._flows = defaultdict(lambda: {"packets": 0, "bytes": 0})
        return old


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


class Reporter:
    def __init__(self, aggregator: FlowAggregator, enricher: IPEnricher, alerter: FlowAlerter, interval: float = 5.0):
        self._aggregator = aggregator
        self._enricher = enricher
        self._alerter = alerter
        self._interval = interval
        self._running = False
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._running = False

    def _loop(self) -> None:
        while self._running:
            time.sleep(self._interval)
            if self._running:
                self._report()

    def _report(self) -> None:
        flows = self._aggregator.flush()
        if not flows:
            return

        total_bytes = sum(v["bytes"] for v in flows.values())
        total_packets = sum(v["packets"] for v in flows.values())

        # Top-10 flows by bytes
        sorted_flows = sorted(flows.items(), key=lambda x: x[1]["bytes"], reverse=True)
        top_flows = [{"key": k, **v} for k, v in sorted_flows[:10]]

        # Aggregate by src_ip
        src_agg: dict[str, int] = defaultdict(int)
        dst_agg: dict[str, int] = defaultdict(int)
        for (src_ip, dst_ip, _, _, _), counters in flows.items():
            src_agg[src_ip] += counters["bytes"]
            dst_agg[dst_ip] += counters["bytes"]

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
            interval_sec=self._interval,
            top_sources=top_sources,
            top_dests=top_dests,
            top_flows=top_flows,
        )


class VXLANProbe:
    def __init__(self):
        self._sock: Optional[socket.socket] = None
        self._running = False
        self._aggregator = FlowAggregator()
        self._enricher = IPEnricher()
        self._alerter = FlowAlerter()
        self._reporter = Reporter(self._aggregator, self._enricher, self._alerter)

    def start(self) -> None:
        self._running = True

        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
        self._sock.settimeout(1.0)
        self._sock.bind(("0.0.0.0", 4789))

        actual_rcvbuf = self._sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        logger.info("Socket bound to 0.0.0.0:4789 (SO_RCVBUF=%d)", actual_rcvbuf)

        self._enricher.start()
        self._reporter.start()

        logger.info("VXLANProbe started")
        self._recv_loop()

    def stop(self) -> None:
        logger.info("VXLANProbe stopping...")
        self._running = False
        self._reporter.stop()
        self._enricher.stop()
        if self._sock:
            self._sock.close()

    def _recv_loop(self) -> None:
        parse = parse_vxlan_packet
        record = self._aggregator.record
        sock = self._sock

        while self._running:
            try:
                data, _ = sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                if self._running:
                    logger.exception("Socket error in recv loop")
                break

            result = parse(data)
            if result:
                key, pkt_len = result
                record(key, pkt_len)


def main() -> None:
    log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    probe = VXLANProbe()

    def handle_signal(signum, frame):
        logger.info("Received signal %d, shutting down", signum)
        probe.stop()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    try:
        probe.start()
    except Exception:
        logger.exception("Fatal error in VXLANProbe")
        probe.stop()
        sys.exit(1)


if __name__ == "__main__":
    main()
