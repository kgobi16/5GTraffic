#!/usr/bin/env bash
# Campaign A: No-QoS baseline — 7 traffic types × 300s (35 min total traffic)
# One xApp instance stays alive; label file updated between runs
set -euo pipefail

PROFILES=(voice video_call video_stream gaming bulk web iot)
QIS=(1 2 8 3 9 5 9)
DURATION=300
CONTAINER=python_xapp_runner
CSV_HOST=/home/kgobi/thesis/data/campaign_A_no_qos.csv
CSV_CTR=/tmp/campaign_A_no_qos.csv
LABEL_FILE_CTR=/tmp/xapp_label.txt
XAPP=/opt/xApps/qos_csv_xapp.py
E2_NODE=gnbd_999_070_00019b_0

echo "[campaign_A] Starting — $(date)"

# Clean up any leftover CSV
sudo docker exec "$CONTAINER" bash -c "rm -f $CSV_CTR" 2>/dev/null || true

# Kill any lingering xApp (no pkill in container — kill by PID via /proc, skip self)
sudo docker exec "$CONTAINER" bash -c "
SELF=\$\$
for pid in \$(ls /proc | grep -E '^[0-9]+\$'); do
    [ \"\$pid\" = \"\$SELF\" ] && continue
    cmd=\$(cat /proc/\$pid/cmdline 2>/dev/null | tr '\0' ' ')
    case \"\$cmd\" in *python3*qos_csv_xapp*) kill -9 \$pid 2>/dev/null && echo \"killed \$pid\" ;; esac
done; true" 2>/dev/null || true
sleep 4
# Verify port 8091 is free
until ! sudo docker exec "$CONTAINER" bash -c "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -qi '1F9D'"; do
    echo "[campaign_A] waiting for port 8091 to free..."; sleep 2
done
echo "[campaign_A] port 8091 free"

# Set initial label
sudo docker exec "$CONTAINER" bash -c "echo '${PROFILES[0]},${QIS[0]}' > $LABEL_FILE_CTR"

# Start single long-running xApp
sudo docker exec -d "$CONTAINER" bash -c "
    cd /opt/xApps && \
    python3 $XAPP \
      --http_server_port 8093 \
      --rmr_port 4563 \
      --e2_node_id $E2_NODE \
      --csv $CSV_CTR \
      --experiment no_qos \
      --traffic_type ${PROFILES[0]} \
      --5qi ${QIS[0]} \
      --label_file $LABEL_FILE_CTR \
    > /tmp/xapp_A.log 2>&1
"
echo "[campaign_A] xApp started — waiting 8s for E2 subscription..."
sleep 8
sudo docker exec "$CONTAINER" bash -c "cat /tmp/xapp_A.log"
# Abort if xApp crashed (no python3 qos_csv_xapp process alive)
XAPP_ALIVE=$(sudo docker exec "$CONTAINER" bash -c "
for pid in \$(ls /proc | grep -E '^[0-9]+\$'); do
    cmd=\$(cat /proc/\$pid/cmdline 2>/dev/null | tr '\0' ' ')
    if echo \"\$cmd\" | grep -q 'python3.*qos_csv_xapp'; then echo \$pid; fi
done" 2>/dev/null)
if [[ -z "$XAPP_ALIVE" ]]; then echo "[campaign_A] ERROR: xApp crashed on startup — aborting"; exit 1; fi
echo "[campaign_A] xApp alive (PID=$XAPP_ALIVE)"

for i in "${!PROFILES[@]}"; do
    PROF="${PROFILES[$i]}"
    QI="${QIS[$i]}"
    echo ""
    echo "=== [$((i+1))/${#PROFILES[@]}] profile=$PROF 5qi=$QI ==="

    # Update label file — xApp picks it up on next callback
    sudo docker exec "$CONTAINER" bash -c "echo '$PROF,$QI' > $LABEL_FILE_CTR"
    echo "[campaign_A] Label updated to $PROF/$QI"

    echo "[campaign_A] Sending traffic: $PROF for ${DURATION}s..."
    python3 /home/kgobi/thesis/traffic_gen.py \
        --profile "$PROF" \
        --duration "$DURATION" \
        --dst_ip 1.2.3.4 \
        --dst_port 5201

    echo "[campaign_A] Done with $PROF"
    # Brief pause between profiles
    sleep 3
done

echo ""
echo "=== Campaign A complete — copying CSV from container ==="
sudo docker cp "$CONTAINER:$CSV_CTR" "$CSV_HOST"
echo "[campaign_A] Saved to $CSV_HOST"
wc -l "$CSV_HOST"
echo "[campaign_A] Finished — $(date)"

# Stop xApp
sudo docker exec "$CONTAINER" bash -c "
SELF=\$\$
for pid in \$(ls /proc | grep -E '^[0-9]+\$'); do
    [ \"\$pid\" = \"\$SELF\" ] && continue
    cmd=\$(cat /proc/\$pid/cmdline 2>/dev/null | tr '\0' ' ')
    case \"\$cmd\" in *python3*qos_csv_xapp*) kill -9 \$pid 2>/dev/null ;; esac
done; true" 2>/dev/null || true
