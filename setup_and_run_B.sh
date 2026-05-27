#!/usr/bin/env bash
# Full pipeline: RIC restart → xApp container check → gNB+srsUE → Campaign B
set -euo pipefail

GNB_BIN=/home/kgobi/srsRAN_Project/build/apps/gnb/gnb
GNB_CFG=/home/kgobi/srsRAN_Project/configs/gnb_zmq.yml
UE_BIN=/home/kgobi/srsRAN_4G/build/srsue/src/srsue
UE_CFG=/home/kgobi/ue_5g_zmq.conf
RIC_DIR=/home/kgobi/oran-sc-ric
E2MGR=http://10.0.2.11:3800
E2_NODE=gnbd_999_070_00019b_0

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

# ── 1. RIC restart ────────────────────────────────────────────────────────────
log "=== Step 1/4: RIC restart ==="
cd "$RIC_DIR"
sudo docker compose down
sudo docker compose up -d
log "Waiting 15s for RIC services to initialise..."
sleep 15

# Verify all 7 containers are running
RUNNING=$(sudo docker ps --filter "name=ric_" --filter "status=running" -q | wc -l)
[ "$RUNNING" -ge 6 ] || die "Only $RUNNING RIC containers running after restart"
log "RIC up — $RUNNING containers running"

# ── 2. xApp container check ───────────────────────────────────────────────────
log "=== Step 2/4: xApp container check ==="
sudo docker ps --filter "name=python_xapp_runner" --filter "status=running" -q | grep -q . \
    || die "python_xapp_runner container is not running"
log "python_xapp_runner container ready"

# Kill any leftover xApp process from a previous run
sudo docker exec python_xapp_runner bash -c "
SELF=\$\$
for pid in \$(ls /proc | grep -E '^[0-9]+\$'); do
    [ \"\$pid\" = \"\$SELF\" ] && continue
    cmd=\$(cat /proc/\$pid/cmdline 2>/dev/null | tr '\0' ' ')
    case \"\$cmd\" in *python3*xapp*) kill -9 \$pid 2>/dev/null && echo \"killed stale xApp PID \$pid\" ;; esac
done; true" 2>/dev/null || true

# ── 3. gNB + srsUE ───────────────────────────────────────────────────────────
log "=== Step 3/4: gNB + srsUE ==="
log "Stopping any existing gNB / srsUE..."
sudo pkill -9 -f "gnb/gnb" 2>/dev/null || true
sudo pkill -9 -f "srsue"   2>/dev/null || true
sleep 4

log "Starting gNB ($GNB_CFG)..."
sudo "$GNB_BIN" -c "$GNB_CFG" >/tmp/gnb.log 2>&1 &
GNB_PID=$!
sleep 5
kill -0 "$GNB_PID" 2>/dev/null || die "gNB exited immediately — check /tmp/gnb.log"

log "Starting srsUE ($UE_CFG)..."
sudo "$UE_BIN" "$UE_CFG" >/tmp/srsue.log 2>&1 &
UE_PID=$!

log "Waiting for PDU session (up to 120s)..."
UE_IP=""
for i in $(seq 1 60); do
    sleep 2
    if grep -q "PDU Session Establishment successful" /tmp/srsue.log 2>/dev/null; then
        UE_IP=$(grep "PDU Session" /tmp/srsue.log | tail -1 | grep -oP 'IP: \K[\d.]+')
        break
    fi
    kill -0 "$UE_PID" 2>/dev/null || die "srsUE died — check /tmp/srsue.log"
done
[ -n "$UE_IP" ] || die "UE did not attach within 120s — check /tmp/srsue.log"
log "UE attached — IP: $UE_IP"

# Restore policy routing so traffic_gen sends via tun_srsue (not default route)
sudo ip rule del from "$UE_IP" iif lo lookup 200 priority 150 2>/dev/null || true
sudo ip route del default dev tun_srsue table 200 2>/dev/null || true
sudo ip rule add from "$UE_IP" iif lo lookup 200 priority 150
sudo ip route add default dev tun_srsue table 200
log "Policy routing restored: src=$UE_IP → tun_srsue (table 200)"

log "Waiting for E2 node registration (up to 60s)..."
for i in $(seq 1 30); do
    sleep 2
    STATUS=$(curl -s "$E2MGR/v1/nodeb/$E2_NODE" 2>/dev/null | grep -o '"connectionStatus":"[^"]*"' | head -1 || true)
    if echo "$STATUS" | grep -qi "connected"; then
        log "E2 node registered: $STATUS"
        break
    fi
    if [ "$i" -eq 30 ]; then
        log "WARNING: E2 node not confirmed connected after 60s (status: $STATUS) — proceeding"
    fi
done

# ── 4. Campaign B ─────────────────────────────────────────────────────────────
log "=== Step 4/4: Campaign B ==="
bash /home/kgobi/thesis/run_campaign_B.sh

log ""
log "══ Pipeline complete ══"
log "Output: /home/kgobi/thesis/data/campaign_B_with_qos.csv"
wc -l /home/kgobi/thesis/data/campaign_B_with_qos.csv
