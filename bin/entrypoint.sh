#!/bin/bash
set -uo pipefail

# === Find bird2 binary ===
BIRD_BIN=""
for candidate in bird2 bird birdc; do
    path=$(which "$candidate" 2>/dev/null)
    if [[ -n "$path" ]]; then
        BIRD_BIN="$path"
        break
    fi
done
if [[ -z "$BIRD_BIN" ]]; then
    BIRD_BIN=$(find /usr/sbin -name "bird*" -type f 2>/dev/null | head -1)
fi

echo "[entrypoint] Found BIRD binary: $BIRD_BIN"

# === Graceful shutdown ===
cleanup() {
    echo "[entrypoint] Caught SIGTERM, withdrawing routes..."
    birdc configure export none 2>/dev/null || true
    sleep 2
    kill -TERM "$BIRD_PID" 2>/dev/null || true
    wait "$BIRD_PID" 2>/dev/null || true
    echo "[entrypoint] Shutdown complete"
    exit 0
}
trap cleanup SIGTERM SIGINT

# === Setup DNS (configurable via ENV) ===
DNS1="${DNS1:-77.88.8.8}"
DNS2="${DNS2:-77.88.8.1}"
echo "nameserver $DNS1" > /etc/resolv.conf
echo "nameserver $DNS2" >> /etc/resolv.conf

# === Wait for network ===
echo "[entrypoint] Waiting for network..."
NET_OK=false
for i in $(seq 1 60); do
    if nc -zw1 "$DNS1" 53 2>/dev/null; then
        echo "[entrypoint] Network ready after ${i}s"
        NET_OK=true
        break
    fi
    sleep 1
done
if [[ "$NET_OK" != "true" ]]; then
    echo "[entrypoint] WARNING: Network not available after 60s"
fi

# === Setup crontab with log rotation ===
CRON_LOG="/var/log/bird2-sync.log"
cat > /tmp/bird2cron <<CRON
0 3 * * * /bin/bird2.sh >> $CRON_LOG 2>&1
# Rotate log weekly (keep 4 weeks)
0 0 * * 0 [ -f $CRON_LOG ] && mv $CRON_LOG ${CRON_LOG}.old && touch $CRON_LOG
CRON
crontab /tmp/bird2cron
rm /tmp/bird2cron
echo "[entrypoint] Crontab set: daily sync at 03:00, weekly log rotation"

# === Run initial list sync ===
echo "[entrypoint] Running initial list sync..."
/bin/bird2.sh || true

# === Start crond ===
crond -f -l 1 &
echo "[entrypoint] crond started"

# === Start BIRD2 ===
echo "[entrypoint] Starting BIRD2..."
$BIRD_BIN -c /etc/bird/bird.conf -f &
BIRD_PID=$!
echo "[entrypoint] BIRD2 started (PID: $BIRD_PID)"
wait "$BIRD_PID"
