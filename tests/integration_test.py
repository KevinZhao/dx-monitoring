#!/usr/bin/env python3
"""Integration test: spin up multiproc_probe, send VXLAN packets, verify reports."""

import multiprocessing
import os
import signal
import socket
import struct
import subprocess
import sys
import time

PROBE_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "probe", "multiproc_probe.py")
TARGET = ("127.0.0.1", 4789)
NUM_FLOWS = 50
PACKETS_PER_FLOW = 200
SEND_BATCH_INTERVAL = 0.0001  # 100us between packets


def build_vxlan_packet(src_ip, dst_ip, proto, src_port, dst_port, payload_size=100):
    """Build a VXLAN-encapsulated packet."""
    vxlan = struct.pack("!II", 0x08000000, 12345 << 8)
    eth = b"\x00" * 12 + struct.pack("!H", 0x0800)
    ip_total = 20 + (8 if proto == 17 else 20) + payload_size
    ip_hdr = struct.pack(
        "!BBHHHBBH4s4s",
        0x45, 0, ip_total, 0, 0, 64, proto, 0,
        socket.inet_aton(src_ip),
        socket.inet_aton(dst_ip),
    )
    if proto in (6, 17):
        transport = struct.pack("!HH", src_port, dst_port) + b"\x00" * (payload_size + (16 if proto == 6 else 4))
    else:
        transport = b"\x00" * payload_size
    return vxlan + eth + ip_hdr + transport


def send_traffic(num_flows, packets_per_flow):
    """Send simulated VXLAN traffic to the probe."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    total_sent = 0

    flows = []
    for i in range(num_flows):
        src_ip = f"10.0.{i // 256}.{i % 256 + 1}"
        dst_ip = f"172.16.{i // 256}.{i % 256 + 1}"
        proto = 6 if i % 3 != 0 else 17
        src_port = 10000 + i
        dst_port = 80 if proto == 6 else 53
        pkt = build_vxlan_packet(src_ip, dst_ip, proto, src_port, dst_port, payload_size=50 + i)
        flows.append((src_ip, dst_ip, proto, src_port, dst_port, pkt))

    print(f"Sending {num_flows} flows x {packets_per_flow} packets = {num_flows * packets_per_flow} total packets...")
    start = time.monotonic()

    for _ in range(packets_per_flow):
        for _, _, _, _, _, pkt in flows:
            sock.sendto(pkt, TARGET)
            total_sent += 1

    elapsed = time.monotonic() - start
    pps = total_sent / elapsed if elapsed > 0 else 0
    print(f"Sent {total_sent} packets in {elapsed:.2f}s ({pps:.0f} pps)")
    sock.close()
    return total_sent


def main():
    print("=" * 60)
    print("Integration Test: multiproc_probe.py")
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
    env["ALERT_THRESHOLD_BPS"] = "999999999999"  # High threshold to avoid alerts
    env["ALERT_THRESHOLD_PPS"] = "999999999"

    print(f"\n[1/5] Starting probe with {num_workers} workers...")
    probe_proc = subprocess.Popen(
        [sys.executable, PROBE_SCRIPT],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    # Wait for workers to start
    time.sleep(3)

    if probe_proc.poll() is not None:
        output = probe_proc.stdout.read()
        print(f"FAIL: Probe exited early with code {probe_proc.returncode}")
        print(output)
        sys.exit(1)

    print(f"  Probe running (pid={probe_proc.pid})")

    # Send traffic
    print(f"\n[2/5] Sending traffic ({NUM_FLOWS} flows, {PACKETS_PER_FLOW} pkt/flow)...")
    total_sent = send_traffic(NUM_FLOWS, PACKETS_PER_FLOW)

    # Wait for report cycle (5s interval + buffer)
    print("\n[3/5] Waiting for report cycle (8s)...")
    time.sleep(8)

    # Send SIGTERM and collect output
    print("\n[4/5] Stopping probe...")
    probe_proc.send_signal(signal.SIGTERM)
    try:
        output, _ = probe_proc.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        probe_proc.kill()
        output, _ = probe_proc.communicate()

    # Parse and verify output
    print("\n[5/5] Verifying results...")
    print("-" * 40)

    lines = output.strip().split("\n")
    report_lines = [l for l in lines if "Report:" in l]
    worker_lines = [l for l in lines if "Worker-" in l and "started" in l]
    coordinator_lines = [l for l in lines if "Coordinator" in l]
    parser_lines = [l for l in lines if "parser" in l.lower()]

    print(f"  Workers started: {len(worker_lines)}")
    for wl in worker_lines:
        print(f"    {wl.split('INFO')[-1].strip()}")

    print(f"  Parser type: ", end="")
    for pl in parser_lines:
        if "using" in pl.lower():
            print(pl.split("INFO")[-1].strip())
            break
    else:
        print("unknown")

    print(f"  Reports generated: {len(report_lines)}")

    total_reported_pkts = 0
    total_reported_bytes = 0
    total_reported_flows = 0
    for rl in report_lines:
        # Parse "Report: N flows, N packets, N bytes"
        try:
            parts = rl.split("Report:")[1].split("|")[0]
            tokens = parts.split(",")
            flows = int(tokens[0].strip().split()[0])
            pkts = int(tokens[1].strip().split()[0])
            byt = int(tokens[2].strip().split()[0])
            total_reported_flows += flows
            total_reported_pkts += pkts
            total_reported_bytes += byt
        except (IndexError, ValueError):
            pass

    print(f"  Total reported packets: {total_reported_pkts}")
    print(f"  Total reported bytes: {total_reported_bytes}")
    print(f"  Total reported flows: {total_reported_flows}")
    print(f"  Packets sent: {total_sent}")

    # Verify
    errors = []

    if len(worker_lines) != num_workers:
        errors.append(f"Expected {num_workers} workers, got {len(worker_lines)}")

    if len(report_lines) == 0:
        errors.append("No reports generated")

    if total_reported_pkts == 0:
        errors.append("Zero packets reported")
    elif total_reported_pkts < total_sent * 0.5:
        errors.append(f"Too few packets: {total_reported_pkts}/{total_sent} ({100*total_reported_pkts/total_sent:.0f}%)")

    if total_reported_flows == 0:
        errors.append("Zero flows reported")

    # Check for errors in output
    error_lines = [l for l in lines if "ERROR" in l or "Traceback" in l or "Exception" in l]
    if error_lines:
        errors.append(f"Errors in output: {error_lines[:3]}")

    print("-" * 40)
    if errors:
        print("FAIL:")
        for e in errors:
            print(f"  - {e}")
        print("\nFull output (last 30 lines):")
        for l in lines[-30:]:
            print(f"  {l}")
        sys.exit(1)
    else:
        drop_rate = 100 * (1 - total_reported_pkts / total_sent) if total_sent > 0 else 0
        print(f"PASS: {total_reported_pkts}/{total_sent} packets captured ({100-drop_rate:.1f}% capture rate)")
        print(f"      {total_reported_flows} unique flows detected (expected ~{NUM_FLOWS})")
        print(f"      {len(worker_lines)} workers, {len(report_lines)} reports")

    sys.exit(0)


if __name__ == "__main__":
    main()
