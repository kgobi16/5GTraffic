#!/usr/bin/env bash
# Background daemon: detects xApp 503 subscription failures and auto-restarts
# Run: nohup sudo bash /home/kgobi/thesis/xapp_recovery.sh > /tmp/xapp_recovery.log 2>&1 &

CONTAINER=python_xapp_runner
XAPP=/opt/xApps/qos_csv_xapp.py
E2_NODE=gnbd_999_070_00019b_0
CSV_CTR=/tmp/campaign_B_with_qos.csv
LABEL_FILE_CTR=/tmp/xapp_label.txt

last_restart_epoch=0

echo "[xapp_recovery] daemon started — $(date)"

while true; do
    sleep 4

    # Only act if xApp process is running (pgrep not in container, use /proc scan)
    XAPP_PID=$(sudo docker exec "$CONTAINER" bash -c "
for pid in \$(ls /proc | grep -E '^[0-9]+\$'); do
    cmd=\$(cat /proc/\$pid/cmdline 2>/dev/null | tr '\0' ' ')
    case \"\$cmd\" in *qos_csv_xapp*) echo \$pid; break;; esac
done" 2>/dev/null || true)
    [[ -z "$XAPP_PID" ]] && continue

    # Check for 503 in current log (file is truncated on each xApp restart, so it's always fresh)
    if ! sudo docker exec "$CONTAINER" grep -q "503" /tmp/xapp_B.log 2>/dev/null; then
        continue
    fi

    NOW=$(date +%s)
    # 90s cooldown to avoid repeated restarts within the same profile
    (( NOW - last_restart_epoch < 90 )) && continue
    last_restart_epoch=$NOW

    echo "[xapp_recovery] 503 detected at $(date) — restarting xApp..."

    # Read current label (PROF,QI)
    LABEL=$(sudo docker exec "$CONTAINER" cat "$LABEL_FILE_CTR" 2>/dev/null || true)
    if [[ -z "$LABEL" ]]; then
        echo "[xapp_recovery] label file empty, skipping"
        continue
    fi
    PROF=$(echo "$LABEL" | cut -d, -f1)
    QI=$(echo "$LABEL"   | cut -d, -f2)
    echo "[xapp_recovery] profile=$PROF 5QI=$QI"

    # Kill stale xApp
    sudo docker exec "$CONTAINER" bash -c "
for pid in \$(ls /proc | grep -E '^[0-9]+\$'); do
    cmd=\$(cat /proc/\$pid/cmdline 2>/dev/null | tr '\0' ' ')
    case \"\$cmd\" in *qos_csv_xapp*) kill -9 \$pid 2>/dev/null && echo \"[xapp_recovery] killed xapp \$pid\";; esac
done; true" 2>/dev/null || true

    # Wait for HTTP port 8093 to free (hex 1F9D)
    while sudo docker exec "$CONTAINER" bash -c \
        "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -qi '1F9D'"; do
        echo "[xapp_recovery] waiting for port 8093..."; sleep 2
    done

    echo "[xapp_recovery] Waiting 20s for submgr to process E2 re-registration..."
    sleep 20

    # Restart xApp (truncates log)
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
> /tmp/xapp_B.log 2>&1" 2>/dev/null

    echo "[xapp_recovery] xApp restarted — waiting 10s for subscription..."
    sleep 10
    echo "[xapp_recovery] xApp log tail:"
    sudo docker exec "$CONTAINER" tail -5 /tmp/xapp_B.log 2>/dev/null || true
    echo "[xapp_recovery] recovery complete at $(date)"
done
