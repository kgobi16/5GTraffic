#!/usr/bin/env bash
# Re-run Campaign B for profiles that failed due to E2 Setup rejection (503 on subscription).
# Appends to existing CSV — does NOT delete data from profiles already collected (voice, iot).
# Fix applied: Redis RNIB cleanup before each gNB restart so e2mgr accepts fresh E2 Setup.
set -euo pipefail

PROFILES=(video_call       video_stream gaming      bulk        web)
IMSIS=(   999700000000002 999700000000004 999700000000003 999700000000009 999700000000005)
QIS=(     2                8           3           9           5)
# video_stream uses 5QI=8 (Non-GBR Buffered Streaming); 5QI=4 fails DRB setup in srsRAN gNB.

DURATION=300
CONTAINER=python_xapp_runner
CSV_HOST=/home/kgobi/thesis/data/campaign_B_with_qos.csv
CSV_CTR=/tmp/campaign_B_with_qos.csv
LABEL_FILE_CTR=/tmp/xapp_label.txt
XAPP=/opt/xApps/qos_csv_xapp.py
E2_NODE=gnbd_999_070_00019b_0
UE_CONF=/home/kgobi/ue_5g_zmq.conf
GNB_BIN=/home/kgobi/srsRAN_Project/build/apps/gnb/gnb
GNB_CFG=/home/kgobi/srsRAN_Project/configs/gnb_zmq.yml

kill_xapp() {
    sudo docker exec "$CONTAINER" bash -c "
SELF=\$\$
for pid in \$(ls /proc | grep -E '^[0-9]+\$'); do
    [ \"\$pid\" = \"\$SELF\" ] && continue
    cmd=\$(cat /proc/\$pid/cmdline 2>/dev/null | tr '\0' ' ')
    case \"\$cmd\" in *python3*qos_csv_xapp*) kill -9 \$pid 2>/dev/null && echo \"killed xapp \$pid\" ;; esac
done; true" 2>/dev/null || true
}

restart_gnb() {
    echo "[rerun] Restarting gNB..."
    sudo pkill -SIGTERM gnb 2>/dev/null || true
    sleep 3
    # Clear stale RNIB so e2mgr accepts the fresh E2 Setup
    sudo docker exec ric_dbaas redis-cli del \
        "{e2Manager},RAN:gnbd_999_070_00019b_0" \
        "{e2Manager},GNB" \
        "{e2Manager},GNB:99F907:0000000000000110011011:0" \
        > /dev/null 2>&1 || true
    sudo truncate -s 0 /tmp/gnb.log 2>/dev/null || true
    sudo chmod 644 /tmp/gnb.log 2>/dev/null || true
    nohup sudo "$GNB_BIN" -c "$GNB_CFG" > /dev/null 2>&1 &
    local waited=0
    while [ $waited -lt 30 ]; do
        sleep 1
        if sudo grep -q "Waiting for request" /tmp/gnb.log 2>/dev/null; then
            echo "[rerun] gNB ZMQ scheduler ready (${waited}s)"
            break
        fi
        waited=$((waited + 1))
    done
    waited=0
    while [ $waited -lt 30 ]; do
        sleep 2
        STATUS=$(curl -s "http://10.0.2.11:3800/v1/nodeb/$E2_NODE" 2>/dev/null \
            | grep -o '"connectionStatus":"[^"]*"' | head -1 || true)
        if echo "$STATUS" | grep -qi "connected"; then
            echo "[rerun] E2 node connected (${waited}s): $STATUS"
            sleep 1
            return 0
        fi
        waited=$((waited + 2))
    done
    echo "[rerun] WARNING: E2 node not confirmed connected after 30s — proceeding anyway"
}

start_xapp() {
    local PROF="$1"
    local QI="$2"
    until ! sudo docker exec "$CONTAINER" bash -c "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -qi '1F9D'"; do
        echo "[rerun] waiting for xapp port 8093 to free..."; sleep 2
    done
    sudo docker exec "$CONTAINER" bash -c "echo '$PROF,$QI' > $LABEL_FILE_CTR"
    sudo docker exec -d "$CONTAINER" bash -c "
    cd /opt/xApps && \
    python3 $XAPP \
      --http_server_port 8093 \
      --rmr_port 4563 \
      --e2_node_id $E2_NODE \
      --csv $CSV_CTR \
      --experiment with_qos \
      --traffic_type $PROF \
      --5qi $QI \
      --label_file $LABEL_FILE_CTR \
    > /tmp/xapp_B.log 2>&1"
    echo "[rerun] xApp started — waiting 8s for E2 subscription..."
    sleep 8
    sudo docker exec "$CONTAINER" tail -5 /tmp/xapp_B.log
    # Verify subscription succeeded (no 503)
    if sudo docker exec "$CONTAINER" grep -q "503" /tmp/xapp_B.log 2>/dev/null; then
        echo "[rerun] ERROR: xApp got 503 — check RIC state. Continuing anyway."
    else
        echo "[rerun] xApp subscription OK"
    fi
}

echo "[rerun] Starting re-run of failed profiles — $(date)"
echo "[rerun] Appending to existing CSV (voice and iot data preserved)"

for i in "${!PROFILES[@]}"; do
    PROF="${PROFILES[$i]}"
    IMSI="${IMSIS[$i]}"
    QI="${QIS[$i]}"
    echo ""
    echo "=== [$((i+1))/${#PROFILES[@]}] profile=$PROF IMSI=$IMSI 5QI=$QI ==="

    echo "[rerun] Stopping srsUE..."
    sudo pkill -SIGTERM srsue 2>/dev/null || true
    sleep 3

    kill_xapp
    sleep 2

    restart_gnb

    start_xapp "$PROF" "$QI"

    sudo sed -i "s/^imsi\s*=.*/imsi = ${IMSI}/" "$UE_CONF"
    echo "[rerun] IMSI set to: $(grep '^imsi' $UE_CONF)"

    echo "[rerun] Starting srsUE..."
    sudo srsue "$UE_CONF" > /tmp/ue_rerun_${PROF}.log 2>&1 &

    echo "[rerun] Waiting for tun_srsue..."
    UE_IP=""
    for attempt in $(seq 1 30); do
        UE_IP=$(ip addr show tun_srsue 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1) || true
        if [[ -n "$UE_IP" ]]; then
            echo "[rerun] UE attached: $UE_IP"
            break
        fi
        sleep 2
    done

    if [[ -z "${UE_IP:-}" ]]; then
        echo "[rerun] ERROR: UE failed to attach for $PROF — skipping"
        continue
    fi

    sudo ip route replace 1.2.3.4/32 dev tun_srsue 2>/dev/null || true

    sudo docker exec "$CONTAINER" bash -c "echo '$PROF,$QI' > $LABEL_FILE_CTR"
    echo "[rerun] Label updated to $PROF/$QI — waiting 3s..."
    sleep 3

    echo "[rerun] Sending traffic: $PROF for ${DURATION}s..."
    python3 /home/kgobi/thesis/traffic_gen.py \
        --profile "$PROF" \
        --duration "$DURATION" \
        --dst_ip 1.2.3.4 \
        --dst_port 5201

    echo "[rerun] Done with $PROF"
    sleep 3
done

echo ""
echo "=== Re-run complete — copying CSV from container ==="
sudo docker cp "$CONTAINER:$CSV_CTR" "$CSV_HOST"
echo "[rerun] Saved to $CSV_HOST"
wc -l "$CSV_HOST"
echo "[rerun] Finished — $(date)"

kill_xapp
sudo pkill -SIGTERM gnb 2>/dev/null || true
sudo pkill -SIGTERM srsue 2>/dev/null || true
