# 5GTraffic

**ML-based QoS Traffic Classification via an O-RAN xApp on a 5G Testbed**

Master's Research Project — UTS 32933 | srsRAN 25.10 + Open5GS 2.7.7 + oran-sc-ric (i-release)

---

## Overview

This project builds a software-defined 5G testbed and uses a custom O-RAN Near-RT RIC xApp to collect KPM (Key Performance Measurement) data across 7 traffic classes — with and without QoS shaping. The collected data is used to train an ML classifier to distinguish 5G QoS flows from radio-layer metrics alone.

**Research question:** Does 5QI-based QoS shaping make traffic classes more or less distinguishable at the RAN layer?

---

## Testbed Architecture

```
Open5GS 5G Core (AMF/SMF/UPF/PCF)
        |  N2/N3
srsRAN Project gNB  ──── E2 (SCTP 36421) ────  oran-sc-ric (Near-RT RIC)
        |  ZeroMQ virtual radio                          |
srsRAN 4G srsUE                               qos_csv_xapp.py (this repo)
        |
  traffic_gen.py (UDP per-profile traffic)
```

---

## Repository Contents

| File | Description |
|------|-------------|
| `qos_csv_xapp.py` | Custom O-RAN xApp — subscribes to E2SM-KPM Style 1, writes `DRB.UEThpDl`, `DRB.UEThpUl`, `DRB.RlcSduDelayDl` to CSV per traffic type |
| `traffic_gen.py` | UDP traffic generator with 7 QoS profiles (voice, video_call, video_stream, gaming, bulk, web, iot) |
| `run_campaign_A.sh` | Campaign A: no-QoS baseline — single xApp instance, label-file switching between profiles |
| `setup_and_run_A.sh` | Full pipeline: RIC restart → gNB → srsUE → Campaign A |
| `run_campaign_B.sh` | Campaign B: QoS-shaped — per-profile gNB + xApp restart with Redis RNIB cleanup fix |
| `run_campaign_B_rerun.sh` | Re-runs the 5 profiles that failed in Campaign B due to E2 Setup 503; appends to existing CSV without overwriting already-collected data |
| `run_video_stream_only.sh` | Targeted single-profile rerun for video_stream (5QI=8); includes UE attach retry logic |
| `xapp_recovery.sh` | Background daemon: auto-detects xApp 503 subscription failures and recovers |
| `methodology.md` | Full methodology: why the xApp approach, architecture, setup steps, troubleshooting |
| `data/campaign_A_no_qos.csv` | Collected data: 718 rows, 7 traffic types, no QoS |
| `data/campaign_B_with_qos.csv` | Collected data: 1369 rows, 7 traffic types, 5QI-shaped |

---

## Prerequisites

- Ubuntu 22.04 / 24.04 / 25.10
- [Open5GS](https://open5gs.org) installed and running (systemd services)
- [srsRAN Project](https://github.com/srsran/srsRAN_Project) built with ZMQ support
- [srsRAN 4G srsUE](https://github.com/srsran/srsRAN_4G) built
- [oran-sc-ric](https://github.com/srsran/oran-sc-ric) cloned and running via Docker Compose

---

## Setup

### 1. Deploy the xApp

Copy `qos_csv_xapp.py` into the oran-sc-ric xApps directory (which is bind-mounted into the container):

```bash
cp qos_csv_xapp.py ~/oran-sc-ric/xApps/python/
```

### 2. Provision Open5GS subscribers

Add one subscriber per traffic class in the Open5GS WebUI or MongoDB. Required IMSIs and 5QI values:

| IMSI | Traffic Type | 5QI |
|------|-------------|-----|
| 999700000000001 | voice | 1 |
| 999700000000002 | video_call | 2 |
| 999700000000004 | video_stream | 8 |
| 999700000000003 | gaming | 3 |
| 999700000000009 | bulk / iot | 9 |
| 999700000000005 | web | 5 |

> **Note:** video_stream uses 5QI=8 (Non-GBR Buffered Streaming). srsRAN gNB fails DRB setup for 5QI=4 (GBR Buffered Streaming).

### 3. Run Campaign A (no QoS baseline)

```bash
bash setup_and_run_A.sh
# Output: data/campaign_A_no_qos.csv
```

### 4. Run Campaign B (with QoS)

```bash
# Start RIC first (fresh Redis state)
cd ~/oran-sc-ric && sudo docker compose down && sudo docker compose up -d
sleep 15

bash run_campaign_B.sh
# Output: data/campaign_B_with_qos.csv
```

### 5. If Campaign B profiles fail (E2 Setup 503)

If some profiles fail due to xApp subscription 503 errors (stale Redis RNIB after gNB restart), use the rerun scripts. They **append** to the existing CSV — already-collected profiles are preserved.

```bash
# Re-run all 5 failed profiles (video_call, video_stream, gaming, bulk, web)
bash run_campaign_B_rerun.sh

# Or re-run video_stream only (with UE attach retry logic)
bash run_video_stream_only.sh
```

See the [Key Engineering Notes](#key-engineering-notes) section for the root cause and Redis fix.

---

## Key Engineering Notes

**Redis RNIB cleanup (Campaign B):** After each per-profile gNB restart, stale Redis entries cause `e2mgr` to reject the fresh E2 Setup with `E2setupFailure`, returning HTTP 503 to the xApp. The fix — deleting three Redis keys before each restart — is baked into `restart_gnb()` in `run_campaign_B.sh`:

```bash
sudo docker exec ric_dbaas redis-cli del \
  "{e2Manager},RAN:gnbd_999_070_00019b_0" \
  "{e2Manager},GNB" \
  "{e2Manager},GNB:99F907:0000000000000110011011:0"
```

---

## Data Schema

```
timestamp, experiment, traffic_type, 5qi, DRB.UEThpDl, DRB.UEThpUl, DRB.RlcSduDelayDl
```

- `DRB.UEThpDl` / `DRB.UEThpUl` — DL/UL throughput (kbps), sampled at 1s granularity via E2SM-KPM Style 1
- `DRB.RlcSduDelayDl` — RLC SDU downlink delay (0.1ms units)
- `experiment` — `no_qos` (Campaign A) or `with_qos` (Campaign B)
