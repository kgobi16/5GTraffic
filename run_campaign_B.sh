#!/usr/bin/env bash
# Campaign B: With QoS — 7 traffic types, each using a dedicated IMSI/5QI subscriber
# gNB + xApp restarted per profile to reset ZMQ timing after each UE kill
set -euo pipefail

PROFILES=(voice       video_call       video_stream gaming      bulk        web         iot)
IMSIS=(   999700000000001 999700000000002 999700000000004 999700000000003 999700000000009 999700000000005 999700000000009)
QIS=(     1           2                8           3           9           5           9)
# Note: video_stream uses 5QI=8 (Non-GBR Buffered Streaming) instead of 5QI=4.
# srsRAN gNB fails DRB setup for 5QI=4 GBR Buffered Streaming; 5QI=8 is semantically equivalent.

DURATION=180
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
    echo "[campaign_B] Restarting gNB..."
    sudo pkill -SIGTERM gnb 2>/dev/null || true
    sleep 3
    # Clear stale RNIB so e2mgr accepts the fresh E2 Setup (avoids E2setupFailure / 503)
    sudo docker exec ric_dbaas redis-cli del \
        "{e2Manager},RAN:gnbd_999_070_00019b_0" \
        "{e2Manager},GNB" \
        "{e2Manager},GNB:99F907:0000000000000110011011:0" \
        > /dev/null 2>&1 || true
    # Truncate log so we only see fresh entries from this restart
    sudo truncate -s 0 /tmp/gnb.log 2>/dev/null || true
    sudo chmod 644 /tmp/gnb.log 2>/dev/null || true
    nohup sudo "$GNB_BIN" -c "$GNB_CFG" > /dev/null 2>&1 &
    # Wait up to 30s for scheduler to be ready ("Waiting for request")
    local waited=0
    while [ $waited -lt 30 ]; do
        sleep 1
        if sudo grep -q "Waiting for request" /tmp/gnb.log 2>/dev/null; then
            sleep 2
            echo "[campaign_B] gNB ready (${waited}s)"
            return 0
        fi
        waited=$((waited + 1))
    done
    echo "[campaign_B] WARNING: gNB ready-state timeout — proceeding anyway"
}

start_xapp() {
    local PROF="$1"
    local QI="$2"
    until ! sudo docker exec "$CONTAINER" bash -c "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -qi '1F9D'"; do
        echo "[campaign_B] waiting for xapp port 8093 to free..."; sleep 2
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
    echo "[campaign_B] xApp started — waiting 8s for E2 subscription..."
    sleep 8
    sudo docker exec "$CONTAINER" tail -5 /tmp/xapp_B.log
}

echo "[campaign_B] Starting — $(date)"

# Clean up any leftover CSV
sudo docker exec "$CONTAINER" bash -c "rm -f $CSV_CTR" 2>/dev/null || true

for i in "${!PROFILES[@]}"; do
    PROF="${PROFILES[$i]}"
    IMSI="${IMSIS[$i]}"
    QI="${QIS[$i]}"
    echo ""
    echo "=== [$((i+1))/${#PROFILES[@]}] profile=$PROF IMSI=$IMSI 5QI=$QI ==="

    # Stop srsUE
    echo "[campaign_B] Stopping srsUE..."
    sudo pkill -SIGTERM srsue 2>/dev/null || true
    sleep 3

    # Kill xApp before gNB restart (gNB restart clears stale E2 subscriptions)
    kill_xapp
    sleep 2

    # Restart gNB — resets ZMQ timing so next UE can attach
    restart_gnb

    # Start fresh xApp for this profile (subscribes to newly-registered E2 node)
    start_xapp "$PROF" "$QI"

    # Patch IMSI in UE config
    sudo sed -i "s/^imsi\s*=.*/imsi = ${IMSI}/" "$UE_CONF"
    echo "[campaign_B] IMSI set to: $(grep '^imsi' $UE_CONF)"

    # Restart srsUE (gNB is already in "Waiting for request" — ZMQ will connect cleanly)
    echo "[campaign_B] Starting srsUE..."
    sudo srsue "$UE_CONF" > /tmp/ue_B_${PROF}.log 2>&1 &

    # Wait for UE to attach
    echo "[campaign_B] Waiting for tun_srsue..."
    UE_IP=""
    for attempt in $(seq 1 30); do
        UE_IP=$(ip addr show tun_srsue 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1) || true
        if [[ -n "$UE_IP" ]]; then
            echo "[campaign_B] UE attached: $UE_IP"
            break
        fi
        sleep 2
    done

    if [[ -z "${UE_IP:-}" ]]; then
        echo "[campaign_B] ERROR: UE failed to attach for $PROF — skipping"
        continue
    fi

    # Restore route via tun_srsue
    sudo ip route replace 1.2.3.4/32 dev tun_srsue 2>/dev/null || true

    # Update xApp label
    sudo docker exec "$CONTAINER" bash -c "echo '$PROF,$QI' > $LABEL_FILE_CTR"
    echo "[campaign_B] Label updated to $PROF/$QI — waiting 3s..."
    sleep 3

    # Run traffic
    echo "[campaign_B] Sending traffic: $PROF for ${DURATION}s..."
    python3 /home/kgobi/thesis/traffic_gen.py \
        --profile "$PROF" \
        --duration "$DURATION" \
        --dst_ip 1.2.3.4 \
        --dst_port 5201

    echo "[campaign_B] Done with $PROF"
    sleep 3
done

echo ""
echo "=== Campaign B complete — copying CSV from container ==="
sudo docker cp "$CONTAINER:$CSV_CTR" "$CSV_HOST"
echo "[campaign_B] Saved to $CSV_HOST"
wc -l "$CSV_HOST"
echo "[campaign_B] Finished — $(date)"

# Final cleanup
kill_xapp
sudo pkill -SIGTERM gnb 2>/dev/null || true
sudo pkill -SIGTERM srsue 2>/dev/null || true
