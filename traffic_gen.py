#!/usr/bin/env python3
"""
Traffic generator for QoS thesis experiments.
Sends UDP at a specified rate/packet-size to force traffic through
tun_srsue → srsUE → ZMQ → gNB (which counts UL KPM metrics).

Usage:
    python3 traffic_gen.py --profile voice --duration 180
"""

import argparse
import random
import socket
import subprocess
import time
import sys

# Traffic profiles  (name, bps, pkt_bytes, burst_ratio)
# burst_ratio < 1.0 = bursty (sleep between bursts)
PROFILES = {
    "voice":           dict(bps=64_000,      pkt=160,  burst=1.0),   # G.711 VoIP
    "video_call":      dict(bps=512_000,     pkt=1200, burst=1.0),   # Video conference
    "video_stream":    dict(bps=2_000_000,   pkt=1400, burst=0.9),   # HLS/DASH stream
    "gaming":          dict(bps=100_000,     pkt=80,   burst=0.3),   # Online gaming (bursty)
    "bulk":            dict(bps=4_000_000,   pkt=1400, burst=1.0),   # TCP bulk / file download
    "web":             dict(bps=200_000,     pkt=500,  burst=0.2),   # Web browsing (bursty)
    "iot":             dict(bps=10_000,      pkt=40,   burst=0.1),   # IoT sensor
}


def _ue_ip():
    """Auto-detect tun_srsue IP; fall back to any-address."""
    try:
        out = subprocess.check_output(
            ["ip", "-4", "addr", "show", "tun_srsue"],
            stderr=subprocess.DEVNULL, text=True)
        for tok in out.split():
            if "." in tok and "/" in tok:
                return tok.split("/")[0]
    except Exception:
        pass
    return ""   # bind to any — kernel picks source via routing table


def run(profile_name: str, duration: int, dst_ip: str, dst_port: int):
    p = PROFILES[profile_name]
    bps = p["bps"]
    pkt_size = p["pkt"]
    burst_ratio = p["burst"]

    ue_ip = _ue_ip()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((ue_ip, 0))
    dst = (dst_ip, dst_port)

    interval = (pkt_size * 8) / bps          # ideal inter-packet gap
    burst_gap = interval / burst_ratio if burst_ratio < 1.0 else interval

    payload = bytes([random.randint(0, 255) for _ in range(pkt_size)])
    t_end = time.time() + duration
    total_pkts = 0
    total_bytes = 0

    print(f"[traffic_gen] profile={profile_name} bps={bps} pkt={pkt_size}B "
          f"burst={burst_ratio} duration={duration}s src={ue_ip or 'any'} dst={dst_ip}:{dst_port}",
          flush=True)

    next_send = time.time()
    while time.time() < t_end:
        now = time.time()
        if now >= next_send:
            sock.sendto(payload, dst)
            total_pkts += 1
            total_bytes += pkt_size
            next_send += burst_gap
        else:
            time.sleep(max(0, next_send - now - 0.0001))

    print(f"[traffic_gen] done: {total_pkts} pkts  {total_bytes/1e6:.2f} MB", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile",  choices=list(PROFILES), required=True)
    parser.add_argument("--duration", type=int, default=180)
    parser.add_argument("--dst_ip",   default="1.2.3.4")
    parser.add_argument("--dst_port", type=int, default=5201)
    args = parser.parse_args()
    run(args.profile, args.duration, args.dst_ip, args.dst_port)
