# 5GTraffic

**Empirical Measurement of 5G QoS via an O-RAN xApp on a Software-Defined Testbed**

Master's Research Project — UTS 32933 | srsRAN Project gNB + srsRAN 4G srsUE + Open5GS 2.7.7 + oran-sc-ric (Near-RT RIC)

---

## Overview

This project designs, implements, and evaluates a fully open-source, end-to-end 5G Standalone testbed running on a single Ubuntu host. A custom Python xApp subscribes to the gNB's E2SM-KPM service model over the O-RAN E2 interface, collects per-second Data Radio across seven traffic classes, and produces a labelled dataset for empirical analysis of how 3GPP QoS scheduling modulates user-plane flows.

**Research question:** How does enabling QoS change observable network behaviour for different traffic types, and can these differences be measured on an open-source testbed? 


**Key findings from two matched experimental campaigns (4,111 one-second KPM samples):**

- QoS introduces a **2–4% mean-throughput overhead** in single-UE conditions
- Throughput variability **roughly doubles** for every traffic class under QoS, contradicting the intuition that GBR shaping regularises traffic
- The zero-throughput sample rate **rises by a factor of 4–6×**, providing direct evidence of admission-control activity

The system is established as a reproducible foundation for future closed-loop machine-learning xApps.

---

## Testbed Architecture

```
Open5GS 5G Core (AMF / SMF / UPF / PCF)
        |  N2 NGAP (SCTP 38412) / N3 GTP-U
srsRAN Project gNB  ──── E2 (SCTP 36421) ────  oran-sc-ric (Near-RT RIC)
        |  ZeroMQ virtual radio                          |
srsRAN 4G srsUE                               qos_csv_xapp.py (this repo)
        |
  traffic_gen.py (UDP per-profile traffic → tun_srsue)
```

All components run on a single Ubuntu 24.04 LTS host. No physical radio hardware is required — the radio link between the gNB and UE is emulated by ZeroMQ.

---

## Repository Contents

| File | Description |
|------|-------------|
| `qos_csv_xapp.py` | Custom O-RAN xApp — subscribes to E2SM-KPM Style 1, writes `DRB.UEThpDl`, `DRB.UEThpUl`, `DRB.RlcSduDelayDl` to CSV, labelled by traffic type and 5QI |
| `traffic_gen.py` | UDP traffic generator with 7 QoS profiles (voice, video_call, video_stream, gaming, bulk, web, iot) modelled on real-world bitrate and burst patterns |
| `setup_and_run_A.sh` | Full pipeline: Near-RT RIC restart → xApp container check → gNB + srsUE → Campaign A |
| `setup_and_run_B.sh` | Full pipeline: Near-RT RIC restart → xApp container check → gNB + srsUE → Campaign B |
| `run_campaign_A.sh` | Campaign A (no-QoS baseline) — single xApp instance, label-file switching between profiles, 300 s per profile |
| `run_campaign_B.sh` | Campaign B (QoS-shaped) — per-profile gNB + xApp restart, per-5QI IMSI, with Redis RNIB cleanup fix |
| `run_campaign_B_rerun.sh` | Re-runs the 5 profiles that failed in Campaign B due to E2 Setup 503; appends to existing CSV |
| `run_video_stream_only.sh` | Targeted single-profile rerun for video_stream (5QI=8); includes UE attach retry logic |
| `xapp_recovery.sh` | Background daemon: auto-detects xApp 503 subscription failures and recovers |
| `methodology.md` | Full methodology: xApp design rationale, architecture, setup steps, troubleshooting |
| `data/campaign_A_no_qos.csv` | Collected dataset: 2,015 one-second KPM rows, 7 traffic types, no QoS |
| `data/campaign_B_with_qos.csv` | Collected dataset: 2,096 one-second KPM rows, 7 traffic types, 5QI-shaped |

---

## Prerequisites

- Ubuntu 22.04 LTS or 24.04 LTS
- [Open5GS](https://open5gs.org) installed and running as systemd services
- [srsRAN Project](https://github.com/srsran/srsRAN_Project) built with ZeroMQ support (`-DENABLE_ZEROMQ=ON`)
- [srsRAN 4G srsUE](https://github.com/srsran/srsRAN_4G) built
- [oran-sc-ric](https://github.com/srsran/oran-sc-ric) cloned and running via Docker Compose
- Docker Engine with the Docker Compose plugin

---

## Setup

### 1. Deploy the xApp

Copy `qos_csv_xapp.py` into the oran-sc-ric xApps directory (which is bind-mounted into the `python_xapp_runner` container):

```bash
cp qos_csv_xapp.py ~/oran-sc-ric/xApps/python/
```

### 2. Provision Open5GS subscribers

Add one subscriber per traffic class in the Open5GS WebUI or MongoDB. Required IMSIs and 5QI values:

| IMSI | Traffic Type | 5QI | QoS Class |
|------|-------------|-----|-----------|
| 999700000000001 | voice | 1 | GBR – Conversational Voice |
| 999700000000002 | video_call | 2 | GBR – Conversational Video |
| 999700000000003 | gaming | 3 | GBR – Real-Time Gaming |
| 999700000000004 | video_stream | 8 | Non-GBR – Buffered Streaming |
| 999700000000005 | web | 5 | Non-GBR – IMS Signalling |
| 999700000000009 | bulk / iot | 9 | Non-GBR – Best Effort |

> **Note:** `video_stream` uses 5QI=8 (Non-GBR Buffered Streaming). The srsRAN gNB fails DRB setup for 5QI=4 (GBR Buffered Streaming), so 5QI=8 is used in both campaigns for a fair comparison.

### 3. Run Campaign A (no-QoS baseline)

```bash
bash ~/thesis/setup_and_run_A.sh
# Output: data/campaign_A_no_qos.csv
```

`setup_and_run_A.sh` is the single entry point. It restarts the Near-RT RIC, verifies the xApp container, brings up the gNB and srsUE, waits for PDU Session Establishment, configures policy routing, and then calls `run_campaign_A.sh`.

### 4. Run Campaign B (with QoS)

```bash
# Start the Near-RT RIC with a clean Redis state
cd ~/oran-sc-ric && sudo docker compose down && sudo docker compose up -d
sleep 15

bash ~/thesis/run_campaign_B.sh
# Output: data/campaign_B_with_qos.csv
```

Campaign B restarts the gNB and xApp for each profile so that a fresh per-5QI subscriber (and its 3GPP QoS policy) is active during each 300-second traffic run.

### 5. If Campaign B profiles fail (E2 Setup 503)

If some profiles fail due to xApp subscription 503 errors (stale Redis RNIB entries after gNB restart), use the rerun scripts. They **append** to the existing CSV — already-collected profiles are preserved.

```bash
# Re-run all 5 failed profiles (video_call, video_stream, gaming, bulk, web)
bash ~/thesis/run_campaign_B_rerun.sh

# Or re-run video_stream only (with UE attach retry logic)
bash ~/thesis/run_video_stream_only.sh
```

See [Key Engineering Notes](#key-engineering-notes) below for the root cause and the Redis fix.

---

## Key Engineering Notes

### Redis RNIB cleanup (Campaign B)

After each per-profile gNB restart, stale Redis Radio Network Information Base (RNIB) entries cause `e2mgr` to reject the fresh E2 Setup with `E2setupFailure`, returning HTTP 503 to the xApp. The fix — deleting three specific Redis keys before each gNB restart — is baked into the `restart_gnb()` function in `run_campaign_B.sh`:

```bash
sudo docker exec ric_dbaas redis-cli del \
  "{e2Manager},RAN:gnbd_999_070_00019b_0" \
  "{e2Manager},GNB" \
  "{e2Manager},GNB:99F907:0000000000000110011011:0"
```

### ZeroMQ timing reset

Because the ZeroMQ virtual radio holds internal state between UE connections, each Campaign B profile requires a full gNB restart (not just a UE restart) to reset ZMQ timing. The srsUE is restarted after the gNB is confirmed ready so it connects to a clean ZMQ socket.

### Policy routing

Traffic generated by `traffic_gen.py` must be sourced from the `tun_srsue` IP to traverse the simulated radio link and register as UE uplink traffic in the gNB's KPM counters. A custom policy routing rule (table 200) is added after each UE attach to enforce this.

---

## Data Schema

```
timestamp, experiment, traffic_type, 5qi, DRB.UEThpDl, DRB.UEThpUl, DRB.RlcSduDelayDl
```

| Field | Description |
|-------|-------------|
| `timestamp` | ISO 8601 collection time |
| `experiment` | `no_qos` (Campaign A) or `with_qos` (Campaign B) |
| `traffic_type` | One of: voice, video_call, video_stream, gaming, bulk, web, iot |
| `5qi` | 3GPP 5G QoS Identifier for this flow |
| `DRB.UEThpDl` | DL per-UE throughput (kbps), 1 s granularity via E2SM-KPM Style 1 |
| `DRB.UEThpUl` | UL per-UE throughput (kbps), 1 s granularity via E2SM-KPM Style 1 |
| `DRB.RlcSduDelayDl` | RLC SDU downlink delay (0.1 ms units) |

**Dataset summary:**

| Campaign | Experiment | Rows | Traffic classes |
|----------|-----------|------|-----------------|
| A | no_qos | 2,015 | 7 |
| B | with_qos | 2,096 | 7 |
| **Total** | | **4,111** | **7** |

---

## Results Summary

Two matched experimental campaigns were executed on Ubuntu 24.04 LTS. The gNB established a stable SCTP-based E2 connection with the Near-RT RIC, and the custom xApp parsed and wrote clean per-second telemetry records labelled with 5QI and S-NSSAI. All functional and performance requirements were verified as passed.

Quantitative analysis of the 4,111-sample dataset confirms three principal findings:

1. **Throughput overhead:** QoS enforcement introduces a 2–4% mean-throughput overhead in single-UE conditions.
2. **Increased variability:** Sub-second throughput variability roughly doubles for every traffic class under QoS, contradicting the intuition that GBR shaping regularises traffic.
3. **Admission-control evidence:** The zero-throughput sample rate rises by a factor of 4–6× under QoS, providing direct empirical evidence of admission-control activity.

The prototype is established as a viable foundation for further machine-learning-based research into closed-loop traffic classification and RAN control.
