#!/usr/bin/env python3
"""Stress test: measure max pps on local machine with multiproc_probe."""

import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

PROBE_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "probe", "multiproc_probe.py")
TARGET = ("127.0.0.1", 4789)
DURATION = 15  # seconds of sustained traffic
NUM_SENDER_THREADS = 4


def build_packet_batch(batch_id, count=100):
    """Pre-build a batch of VXLAN packets for fast sending."""
    packets = []
    for i in range(count):
        src_ip = f"10.{batch_id}.{i // 256}.{i % 256 + 1}"
        dst_ip = f"172.16.{batch_id}.{i % 256 + 1}"
        proto = 6
        src_port = 10000 + i
        dst_port = 443
        vxlan = struct.pack("!II", 0x08000000, 12345 << 8)
        eth = b"\x00" * 12 + struct.pack("!H", 0x0800)
        ip_hdr = struct.pack(
            "!BBHHHBBH4s4s",
            0x45, 0, 60, 0, 0, 64, proto, 0,
            socket.inet_aton(src_ip),
            socket.inet_aton(dst_ip),
        )
        transport = struct.pack("!HH", src_port, dst_port) + b"\x00" * 16
        packets.append(vxlan + eth + ip_hdr + transport)
    return packets


def sender_thread(thread_id, stop_event, counter):
    """Send packets as fast as possible."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    packets = build_packet_batch(thread_id, count=200)
    local_count = 0
    idx = 0
    num_pkts = len(packets)

    while not stop_event.is_set():
        try:
            sock.sendto(packets[idx], TARGET)
            local_count += 1
            idx = (idx + 1) % num_pkts
        except OSError:
            break

    counter[thread_id] = local_count
    sock.close()


def main():
    print("=" * 60)
    print(f"Stress Test: {DURATION}s sustained traffic, {NUM_SENDER_THREADS} sender threads")
    print("=" * 60)

    num_workers = min(os.cpu_count() or 2, 4)
    env = os.environ.copy()
    env["PROBE_WORKERS"] = str(num_workers)
    env["PROBE_SAMPLE_RATE"] = "1.0"
    env["LOG_LEVEL"] = "INFO"
    env["SNS_TOPIC_ARN"] = ""
    env["SLACK_WEBHOOK_URL"] = ""
    env["VPC_ID"] = ""
    env["AWS_REGION"] = "eu-central-1"
    env["ALERT_THRESHOLD_BPS"] = "999999999999"
    env["ALERT_THRESHOLD_PPS"] = "999999999"

    print(f"\nStarting probe ({num_workers} workers)...")
    probe_proc = subprocess.Popen(
        [sys.executable, PROBE_SCRIPT],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    time.sleep(3)

    if probe_proc.poll() is not None:
        output = probe_proc.stdout.read()
        print(f"FAIL: Probe exited early: {output[-500:]}")
        sys.exit(1)

    # Start sender threads
    stop_event = threading.Event()
    counters = [0] * NUM_SENDER_THREADS
    threads = []
    for i in range(NUM_SENDER_THREADS):
        t = threading.Thread(target=sender_thread, args=(i, stop_event, counters))
        t.start()
        threads.append(t)

    print(f"Sending traffic for {DURATION}s...")
    start = time.monotonic()
    time.sleep(DURATION)
    stop_event.set()

    for t in threads:
        t.join(timeout=5)
    elapsed = time.monotonic() - start

    total_sent = sum(counters)
    send_pps = total_sent / elapsed

    print(f"\nSend complete: {total_sent:,} packets in {elapsed:.1f}s ({send_pps:,.0f} pps)")
    for i, c in enumerate(counters):
        print(f"  Sender-{i}: {c:,} packets")

    # Wait for final report
    time.sleep(7)

    # Stop probe
    probe_proc.send_signal(signal.SIGTERM)
    try:
        output, _ = probe_proc.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        probe_proc.kill()
        output, _ = probe_proc.communicate()

    # Parse reports
    lines = output.strip().split("\n")
    report_lines = [l for l in lines if "Report:" in l]

    total_pkts = 0
    total_bytes = 0
    for rl in report_lines:
        try:
            parts = rl.split("Report:")[1].split("|")[0]
            tokens = parts.split(",")
            pkts = int(tokens[1].strip().split()[0])
            byt = int(tokens[2].strip().split()[0])
            total_pkts += pkts
            total_bytes += byt
        except (IndexError, ValueError):
            pass

    parser_type = "Python"
    for l in lines:
        if "using C parser" in l:
            parser_type = "C"
            break

    capture_rate = (total_pkts / total_sent * 100) if total_sent > 0 else 0
    recv_pps = total_pkts / elapsed if elapsed > 0 else 0

    print(f"\n{'=' * 60}")
    print(f"Results:")
    print(f"  Parser:          {parser_type}")
    print(f"  Workers:         {num_workers}")
    print(f"  Sent:            {total_sent:>12,} packets ({send_pps:>10,.0f} pps)")
    print(f"  Captured:        {total_pkts:>12,} packets ({recv_pps:>10,.0f} pps)")
    print(f"  Capture rate:    {capture_rate:.1f}%")
    print(f"  Reports:         {len(report_lines)}")
    print(f"  Total bytes:     {total_bytes:>12,}")

    # Check for drops in /proc/net/udp
    try:
        with open("/proc/net/udp") as f:
            for line in f:
                if ":12B5" in line.upper():  # 4789 in hex = 12B5
                    parts = line.split()
                    if len(parts) >= 13:
                        drops = int(parts[12])
                        print(f"  /proc/net/udp drops: {drops}")
    except Exception:
        pass

    # Check errors
    error_lines = [l for l in lines if "ERROR" in l or "Traceback" in l]
    if error_lines:
        print(f"\n  Errors ({len(error_lines)}):")
        for e in error_lines[:5]:
            print(f"    {e}")

    print(f"{'=' * 60}")

    if capture_rate < 50:
        print("WARNING: High packet loss — expected on local loopback test")
    if capture_rate >= 95:
        print("EXCELLENT: Near-zero loss")

    sys.exit(0)


if __name__ == "__main__":
    main()
