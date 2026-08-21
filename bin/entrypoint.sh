#!/bin/bash

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

# === Setup DNS ===
echo "nameserver 77.88.8.8" > /etc/resolv.conf
echo "nameserver 77.88.8.1" >> /etc/resolv.conf

# === Wait for network ===
echo "[entrypoint] Waiting for network..."
for i in $(seq 1 60); do
    if nc -zw1 77.88.8.8 53 2>/dev/null; then
        echo "[entrypoint] Network ready after ${i}s"
        break
    fi
    sleep 1
done

# === Setup crontab for daily list sync ===
CRON_LOG="/var/log/bird2-sync.log"
echo "0 3 * * * /bin/bird2.sh >> $CRON_LOG 2>&1" > /tmp/bird2cron
crontab /tmp/bird2cron
rm /tmp/bird2cron
echo "[entrypoint] Crontab set: daily sync at 03:00"

# === Run initial list sync ===
echo "[entrypoint] Running initial list sync..."
/bin/bird2.sh || true

# === Start crond ===
crond -f -l 1 &
echo "[entrypoint] crond started"

# === Start BIRD2 ===
echo "[entrypoint] Starting BIRD2..."
exec $BIRD_BIN -c /etc/bird/bird.conf -f
