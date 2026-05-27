# Master's Thesis Methodology: QoS Traffic Classification via O-RAN xApp

**Testbed:** srsRAN Project 25.10 + srsRAN 4G srsUE + Open5GS + ZeroMQ on Ubuntu Linux
**Approach selected:** O-RAN xApp (Extended Application) on a Near-RT RIC (Near-Real-Time RAN Intelligent Controller)

---

## 1. Why the xApp Approach Was Selected

After evaluating both the native source-code modification path and the O-RAN xApp path, **the xApp approach is the better fit for this Master's research project** for seven concrete reasons.

### 1.1 The xApp path produces a defensible, standards-aligned thesis contribution

O-RAN is the dominant standardisation effort reshaping the global RAN industry, with major operators (AT&T, Vodafone, Deutsche Telekom, Verizon, Rakuten) publicly committed to O-RAN deployments. A thesis built around an xApp puts the work **directly in the path of industry adoption**. By contrast, modifying srsRAN source code produces a research artefact that lives only inside one fork of one open-source project — much harder to defend as having broader scientific or industrial relevance.

When the external examiner asks *"so what?"*, the answer with an xApp is clean: *"This is an O-RAN-conformant xApp running on a standards-compliant Near-RT RIC over the E2 interface, using E2 Service Model – Key Performance Measurement (E2SM-KPM) v3.00. The methodology is reproducible on any vendor's compliant RAN."* That is a much stronger position than *"I patched lib/sdap/sdap_entity_tx_impl.cpp."*

### 1.2 Non-invasive — the testbed stays on the upstream release

The native-modification path forks both srsRAN Project and Open5GS. Every upstream release brings merge conflicts. For a 6–12 month Master's project, this maintenance overhead is real risk. The xApp approach leaves the upstream binaries untouched. You can run `git pull` on srsRAN, rebuild, and your xApp keeps working without modification because the E2 interface is a stable contract.

### 1.3 The xApp produces a real-time, online classifier — a stronger thesis demo

A native-instrumentation thesis culminates in *"here is a CSV of QoS-labelled packets and an offline-trained Random Forest"*. An xApp thesis culminates in *"here is a live demo where my xApp subscribes to the gNB over E2, receives KPM Indications every 100 ms, runs an ML model in-loop, and classifies QoS flows in real time — and optionally sends an E2SM-RC (RAN Control) action back to the gNB to adjust scheduling"*. The second demo is far more compelling at a thesis defence and at conference submissions (IEEE NetSoft, GLOBECOM, ITC).

### 1.4 The Near-RT RIC ecosystem is mature and well-supported

The `srsran/oran-sc-ric` repository — maintained by Software Radio Systems themselves in lockstep with srsRAN releases — provides a Docker-Compose bundle that brings up the entire Near-RT RIC stack with one command. xApps are written in Python with a documented `xAppBase` class. There are working example xApps (`kpm_mon_xapp.py`, `rc_xapp.py`) that subscribe to KPM and receive QoS-labelled metrics out of the box.

### 1.5 The data exposed by E2SM-KPM is sufficient for QoS classification

A common misconception is that E2SM-KPM is "just throughput numbers". In fact, srsRAN 25.10's E2SM-KPM provider exposes ~20 DRB-level metrics (Data Radio Bearer-level) with the **5QI label, slice label, and PLMN-ID label** attached:

- Per-UE downlink and uplink throughput, decomposable per 5QI
- RLC SDU delay (Radio Link Control Service Data Unit), air-interface delay, PDCP SDU delay
- PDCP SDU volume (downlink and uplink, per 5QI)
- RLC packet drop rate
- RLC throughput distributions
- PRB utilisation (Physical Resource Block)
- Per-UE RSRP, RSRQ, CQI (Reference Signal Received Power, Quality, Channel Quality Indicator)
- Connection counts and RRC (Radio Resource Control) state

These metrics, sampled at 100 ms granularity over multi-minute experiments, give you 1000+ samples per flow with rich features for ML. That is more than sufficient for Random Forest, XGBoost, and even small neural networks.

### 1.6 The 100 ms granularity ceiling is acceptable for QoS classification

The xApp's main limitation versus native instrumentation is granularity: KPM reports aggregate at ≥100 ms, so you cannot get per-packet inter-arrival times. **For QoS class classification specifically, this does not matter.** QoS classes differ on properties — average throughput, jitter, drop rate, PRB allocation patterns — that are all visible at 100 ms. Per-packet timing matters for fingerprinting individual TLS applications, not for separating 5QI=1 (voice) from 5QI=9 (best-effort).

If you later need packet-level features for a richer ablation study, you can add a complementary `tcpdump` on `ogstun` and join offline. The xApp is the primary instrument; the PCAP is a supplementary source.

### 1.7 Scope and effort match a Master's timeline

Native instrumentation requires reading and modifying srsRAN's C++ codebase across SDAP, PDCP, CU-UP, and the scheduler — a substantial systems-programming effort just to get usable data. The xApp approach lets you spend your time where the thesis contribution lives: the **ML methodology, the experimental design, and the analysis of how QoS shaping affects classification accuracy**. The infrastructure is solved; you focus on science.

### Summary table

| Dimension | xApp (selected) | Native modification |
|---|---|---|
| Thesis novelty framing | Standards-aligned O-RAN research | Internal source-code patching |
| Maintenance over 12 months | Low (E2 is stable) | High (merge conflicts per release) |
| Real-time / online demo | Yes, live closed-loop possible | No, offline only |
| Setup time to first data | 1–2 weeks | 3–4 weeks |
| Granularity of features | ≥100 ms aggregated | Per-packet |
| Sufficient for QoS classification? | Yes | Yes (overkill) |
| Industry / publication relevance | High | Medium |
| Programming language | Python | C++/C |
| Risk to thesis timeline | Low | Medium-high |

The xApp path is the right choice.

---

## 2. Architecture Overview

Once you complete this setup, your environment will look like this:

```
+------------------------+                     +-------------------+
|  Open5GS 5G Core       |                     |  Near-RT RIC      |
|  (AMF, SMF, UPF, PCF)  |<---N4 PFCP--------->|  (oran-sc-ric)    |
|  + MongoDB + WebUI     |                     |  Docker-Compose   |
+------------------------+                     +-------------------+
            ^                                          ^
            | N2 NGAP (SCTP 38412)                     | E2 (SCTP 36421)
            | N3 GTP-U (UDP 2152)                      |
            v                                          v
+------------------------+                     +-------------------+
|  srsRAN Project gNB    |<--- E2 KPM ------->|  Your xApp        |
|  (5G base station)     |       Indications   |  (Python)         |
|  + E2 Agent enabled    |                     |  Subscribes,      |
+------------------------+                     |  collects CSV,    |
            ^                                  |  runs ML model    |
            | ZeroMQ virtual radio             +-------------------+
            v
+------------------------+
|  srsRAN 4G srsUE       |
|  (Virtual phone)       |
+------------------------+
            ^
            | iperf3, ffmpeg, SIPp, curl
            | (traffic generators per QoS class)
            v
       Test Server (10.45.0.1)
```

Data flow during an experiment: the UE generates traffic of different QoS classes through the testbed; the gNB schedules each flow according to its 5QI; the gNB's E2 agent reports KPM metrics every 100 ms to the Near-RT RIC; your xApp receives the metrics tagged with their 5QI label and writes them to CSV; offline, you train an ML classifier on the CSV.

---

## 3. Step-by-Step Setup on Ubuntu

These instructions assume Ubuntu 22.04 LTS or 24.04 LTS, with srsRAN Project, srsRAN 4G srsUE, and Open5GS already installed and working from your previous setup. We will now add the Near-RT RIC and an xApp.

### Step 3.1: Install Docker and Docker Compose

The `oran-sc-ric` bundle runs as a set of Docker containers, so we need Docker.

```bash
# Update package lists
sudo apt update

# Install prerequisites
sudo apt install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker engine and compose plugin
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add your user to the docker group (so you don't need sudo every time)
sudo usermod -aG docker $USER

# IMPORTANT: log out and log back in for group membership to take effect
# Or run: newgrp docker
```

Verify Docker works:

```bash
docker --version
docker compose version
docker run --rm hello-world
```

### Step 3.2: Clone the oran-sc-ric repository

This is the Near-RT RIC bundle maintained by Software Radio Systems.

```bash
cd ~
git clone https://github.com/srsran/oran-sc-ric.git
cd oran-sc-ric
ls -la
```

You should see directories like `docker-compose.yml`, `xApps/`, and configuration files. Your example xApps live in `xApps/python/`.

### Step 3.3: Bring up the Near-RT RIC

The first time you run this, it will pull several Docker images (~2 GB total) — give it 5–10 minutes on a typical home connection.

```bash
cd ~/oran-sc-ric
docker compose up -d
```

The `-d` flag runs the containers in the background. Check they are all running:

```bash
docker compose ps
```

You should see containers for:
- `ric_submgr` — Subscription Manager
- `ric_e2term` — E2 Termination point
- `ric_e2mgr` — E2 Manager
- `ric_rtmgr` — Routing Manager
- `ric_appmgr` — Application Manager
- `python_xapp_runner` — runtime for Python xApps
- A few support services (Redis, etc.)

To watch the logs of all containers in real time:

```bash
docker compose logs -f
```

To stop the RIC later: `docker compose down`. To restart cleanly: `docker compose down && docker compose up -d`.

### Step 3.4: Configure the srsRAN gNB to enable the E2 agent

The gNB needs to be told to connect to the RIC over the E2 interface. Edit your existing gNB config file (the one that worked in your prior setup):

```bash
sudo nano ~/srsRAN_Project/configs/gnb_zmq.yml
```

Add the following blocks (or merge them into your existing file):

```yaml
# Enable the E2 agent at the DU
e2:
  enable_du_e2: true              # Connect this gNB's DU to the RIC
  e2sm_kpm_enabled: true          # Enable Key Performance Measurement service model
  e2sm_rc_enabled: false          # Leave RC off for now; enable later for closed-loop
  addr: 127.0.0.1                 # IP of the RIC's E2 termination point
  port: 36421                     # Standard E2 port
  bind_addr: 127.0.0.1            # Local IP the gNB binds to for E2

# Enable detailed metrics — REQUIRED for E2SM-KPM to populate values
metrics:
  enable_json: true
  addr: 127.0.0.1
  port: 55555
  layers:
    enable_sched: true            # Scheduler metrics — essential for QoS studies
    enable_mac: true              # MAC layer metrics
    enable_rlc: true              # CRITICAL — without this, KPM returns zeros
    enable_pdcp: true             # PDCP byte counters
    enable_rrc: true              # RRC connection state
    enable_ngap: true             # NGAP metrics
  periodicity:
    du_report_period: 1000        # Report every 1000 ms (= 1 second)

# Enable PCAP for E2 messages — useful for debugging
pcap:
  e2ap_enable: true
  e2ap_du_filename: /tmp/gnb_du_e2ap.pcap
  n3_enable: true
  n3_filename: /tmp/gnb_n3.pcap
  ngap_enable: true
  ngap_filename: /tmp/gnb_ngap.pcap
```

Save with `Ctrl+O`, `Enter`, then `Ctrl+X`.

**Critical note:** The `enable_rlc: true` line is the most common cause of "my xApp returns zero values". Without it, the E2SM-KPM provider has no RLC counters to emit. Always enable it.

### Step 3.5: Start the testbed in the correct order

The bring-up order matters. Components must be ready before downstream components try to connect. Open four terminals:

**Terminal 1 — Open5GS 5G Core** (already installed from your previous setup; should be running as systemd services):

```bash
# Check Open5GS services are running
sudo systemctl status open5gs-amfd open5gs-smfd open5gs-upfd open5gs-pcfd

# If any are stopped, start them all
sudo systemctl start open5gs-amfd open5gs-smfd open5gs-upfd open5gs-pcfd \
                     open5gs-ausfd open5gs-udmd open5gs-udrd open5gs-bsfd open5gs-nrfd
```

**Terminal 2 — Near-RT RIC** (bring up after the core):

```bash
cd ~/oran-sc-ric
docker compose up -d
docker compose logs -f ric_e2term     # Watch for "E2 Term started" message
```

Wait until you see the E2 Termination service listening on port 36421. Press `Ctrl+C` to detach from logs (containers keep running).

**Terminal 3 — gNB** (start after RIC is ready):

```bash
sudo gnb -c ~/srsRAN_Project/configs/gnb_zmq.yml
```

In the gNB output, watch for these lines confirming everything connected:

```
N2: Connection to AMF on 127.0.0.5:38412 completed       <- Connected to 5G Core
E2 Setup procedure completed                              <- Connected to Near-RT RIC
==== gNB started ===
```

If you see the E2 line but no "==== gNB started ===", check your AMF config in Open5GS. If you see "==== gNB started ===" but no E2 line, check the RIC logs in Terminal 2.

**Terminal 4 — srsUE virtual phone** (after gNB is up):

```bash
sudo srsue ~/ue_5g_zmq.conf
```

Wait until you see `PDU Session Established` and the `tun_srsue` interface appears.

### Step 3.6: Verify the E2 connection from the RIC side

In a new terminal:

```bash
cd ~/oran-sc-ric
docker compose logs ric_e2term | grep -i "e2 setup"
```

You should see lines like:

```
[NEAR-RIC]: Accepting RAN function ID 2 with def = ORAN-E2SM-KPM
[NEAR-RIC]: E2 Setup Response sent to gNB
```

This confirms the gNB's E2 agent has registered with the RIC and the KPM service model is available.

### Step 3.7: Run the example KPM monitor xApp

The `oran-sc-ric` bundle ships with a working KPM monitor xApp that prints metrics to the console. This is the fastest way to verify everything works end-to-end before writing your own.

```bash
cd ~/oran-sc-ric
docker compose exec python_xapp_runner ./simple_mon_xapp.py \
    --metrics=DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl,DRB.PdcpSduVolumeDL \
    --kpm_report_style=5
```

Generate some traffic from a fifth terminal so the metrics are non-zero:

```bash
ping -I tun_srsue -i 0.2 8.8.8.8     # Light constant traffic
# Or:
iperf3 -c 10.45.0.1 -t 60            # Heavy throughput (needs iperf3 server on 10.45.0.1)
```

You should see the xApp printing rows like:

```
KPM Indication received from gNB at 2026-05-01 14:32:11
  UE 0001:
    DRB.UEThpDl  = 1024.5 kbps   [5QI=9, S-NSSAI=1-000001]
    DRB.UEThpUl  =  512.2 kbps   [5QI=9, S-NSSAI=1-000001]
    DRB.RlcSduDelayDl = 12.3 [0.1ms units]
    DRB.PdcpSduVolumeDL = 128000 bytes
```

If you see this, you have a fully functioning O-RAN xApp pipeline. **This is the foundation of your entire thesis.** Everything else is ML and experimental design built on top.

### Step 3.8: Common issues and fixes

| Symptom | Cause | Fix |
|---|---|---|
| All metric values are 0 | `enable_rlc` / `enable_sched` off | Set both to `true` in gNB `metrics.layers` |
| gNB log: "E2 Setup failed" | RIC not running or wrong port | `docker compose ps`; check `e2.port: 36421` |
| RIC log: "PLMN unknown" | gNB PLMN doesn't match Open5GS | Match PLMN/TAC across all configs |
| `permission denied` on Docker | User not in `docker` group | `sudo usermod -aG docker $USER`, log out/in |
| xApp can't connect | RIC SubMgr not ready | `docker compose logs ric_submgr`; restart |
| gNB reconnect stuck for 60s | RIC time-to-wait timer | Wait 60s, or `docker compose restart` |
| KPM v2/v3 mismatch | Old RIC image cached | `docker compose pull` to fetch latest |

---

## 4. Next Steps After Setup

Once the example xApp prints non-zero metrics:

1. **Write your custom xApp** — fork `simple_mon_xapp.py`, write each KPM Indication to a CSV row tagged with the 5QI and timestamp. Aim for ~10 lines of code change.
2. **Provision multiple 5QI subscribers in Open5GS** — one subscriber per 5QI class (5QI=1 voice, 5QI=2 video, 5QI=4 streaming, 5QI=9 default). The srsUE multi-flow limitation means one-subscriber-per-class is more reliable than dynamic PCC modify.
3. **Build traffic generators** — SIPp for VoNR (5QI=1), GStreamer/ffmpeg for video (5QI=2/4), iperf3 for bulk (5QI=9). Run them with deterministic schedules.
4. **Capture campaigns** — run 10–30 minute experiments per QoS class, collecting the xApp CSV plus a supplementary `tcpdump -i ogstun` PCAP.
5. **Train ML models** — start with Random Forest on time-windowed features from the CSV; macro-F1 as primary metric; flow-aware 5-fold cross-validation.
6. **The headline experiment** — train on QoS-shaped data, test on best-effort-only data and vice versa. Quantify how QoS shaping changes classification accuracy.

You now have everything you need to start producing thesis data.

---

## 5. Quick Reference: Daily Startup Commands

Once everything is configured, your daily workflow becomes:

```bash
# Terminal 1: Verify Open5GS is running
sudo systemctl status open5gs-amfd

# Terminal 2: Start the RIC
cd ~/oran-sc-ric && docker compose up -d

# Terminal 3: Start the gNB
sudo gnb -c ~/srsRAN_Project/configs/gnb_zmq.yml

# Terminal 4: Start the UE
sudo srsue ~/ue_5g_zmq.conf

# Terminal 5: Start your xApp
cd ~/oran-sc-ric
docker compose exec python_xapp_runner ./your_qos_xapp.py --output=run01.csv

# Terminal 6: Generate traffic
iperf3 -c 10.45.0.1 -t 600
```

Stop everything cleanly:

```bash
# Stop UE and gNB with Ctrl+C in their terminals
cd ~/oran-sc-ric && docker compose down
sudo systemctl stop open5gs-amfd open5gs-smfd open5gs-upfd
```
