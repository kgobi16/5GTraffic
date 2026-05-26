#!/usr/bin/env bash
# Single-profile re-run for video_stream (IMSI=999700000000004, 5QI=8)
# Appends to existing CSV
set -euo pipefail

PROF=video_stream
IMSI=999700000000004
QI=8
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

echo "[vs_rerun] Starting video_stream only — $(date)"

# Kill stale processes
echo "[vs_rerun] Stopping srsUE and xApp..."
sudo pkill -SIGTERM srsue 2>/dev/null || true
sleep 2

# Kill xApp
sudo docker exec "$CONTAINER" bash -c "
for pid in \$(ls /proc | grep -E '^[0-9]+\$'); do
    cmd=\$(cat /proc/\$pid/cmdline 2>/dev/null | tr '\0' ' ')
    case \"\$cmd\" in *python3*qos_csv_xapp*) kill -9 \$pid 2>/dev/null && echo \"killed xapp \$pid\";; esac
done; true" 2>/dev/null || true
sleep 2

# Restart gNB with Redis cleanup
echo "[vs_rerun] Restarting gNB..."
sudo pkill -SIGTERM gnb 2>/dev/null || true
sleep 3
sudo docker exec ric_dbaas redis-cli del \
    "{e2Manager},RAN:gnbd_999_070_00019b_0" \
    "{e2Manager},GNB" \
    "{e2Manager},GNB:99F907:0000000000000110011011:0" \
    > /dev/null 2>&1 || true
sudo truncate -s 0 /tmp/gnb.log 2>/dev/null || true
sudo chmod 644 /tmp/gnb.log 2>/dev/null || true
nohup sudo "$GNB_BIN" -c "$GNB_CFG" > /dev/null 2>&1 &

waited=0
while [ $waited -lt 30 ]; do
    sleep 1
    if sudo grep -q "Waiting for request" /tmp/gnb.log 2>/dev/null; then
        sleep 2
        echo "[vs_rerun] gNB ready (${waited}s)"
        break
    fi
    waited=$((waited + 1))
done

# Start xApp
until ! sudo docker exec "$CONTAINER" bash -c "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -qi '1F9D'"; do
    echo "[vs_rerun] waiting for port 8093..."; sleep 2
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
> /tmp/xapp_vs.log 2>&1"
echo "[vs_rerun] xApp started — waiting 8s..."
sleep 8
sudo docker exec "$CONTAINER" tail -5 /tmp/xapp_vs.log

# Patch IMSI
sudo sed -i "s/^imsi\s*=.*/imsi = ${IMSI}/" "$UE_CONF"
echo "[vs_rerun] IMSI set to: $(grep '^imsi' $UE_CONF)"

# Start UE — retry up to 3 times
for attempt in 1 2 3; do
    echo "[vs_rerun] Starting srsUE (attempt $attempt)..."
    sudo pkill -SIGTERM srsue 2>/dev/null || true; sleep 2
    sudo srsue "$UE_CONF" > /tmp/ue_vs.log 2>&1 &
    UE_IP=""
    for tick in $(seq 1 30); do
        UE_IP=$(ip addr show tun_srsue 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1) || true
        if [[ -n "$UE_IP" ]]; then
            echo "[vs_rerun] UE attached: $UE_IP (attempt $attempt)"
            break
        fi
        sleep 2
    done
    [[ -n "${UE_IP:-}" ]] && break
    echo "[vs_rerun] Attempt $attempt failed — retrying..."
    sudo pkill -SIGTERM srsue 2>/dev/null || true
    sleep 5
done

if [[ -z "${UE_IP:-}" ]]; then
    echo "[vs_rerun] ERROR: UE failed to attach after 3 attempts"
    sudo tail -20 /tmp/ue_vs.log
    exit 1
fi

sudo ip route replace 1.2.3.4/32 dev tun_srsue 2>/dev/null || true
sudo docker exec "$CONTAINER" bash -c "echo '$PROF,$QI' > $LABEL_FILE_CTR"
sleep 3

echo "[vs_rerun] Sending traffic: $PROF for ${DURATION}s..."
python3 /home/kgobi/thesis/traffic_gen.py \
    --profile "$PROF" \
    --duration "$DURATION" \
    --dst_ip 1.2.3.4 \
    --dst_port 5201

echo "[vs_rerun] Done. Copying CSV..."
sudo docker cp "$CONTAINER:$CSV_CTR" "$CSV_HOST"
wc -l "$CSV_HOST"
echo "[vs_rerun] Finished — $(date)"

# Cleanup
sudo docker exec "$CONTAINER" bash -c "
for pid in \$(ls /proc | grep -E '^[0-9]+\$'); do
    cmd=\$(cat /proc/\$pid/cmdline 2>/dev/null | tr '\0' ' ')
    case \"\$cmd\" in *python3*qos_csv_xapp*) kill -9 \$pid 2>/dev/null;; esac
done; true" 2>/dev/null || true
sudo pkill -SIGTERM gnb 2>/dev/null || true
sudo pkill -SIGTERM srsue 2>/dev/null || true
