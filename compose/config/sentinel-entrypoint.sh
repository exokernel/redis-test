#!/bin/sh
# Generates sentinel config on first boot, then starts redis-sentinel.
# On subsequent restarts, the sentinel-rewritten config is preserved (contains
# updated master address after any failover).
#
# Redis 6.2 sentinel requires a resolvable IP at config parse time, so we
# resolve the hostname here before writing the config.
set -e

CONFIG=/sentinel-data/sentinel.conf

if [ ! -f "$CONFIG" ]; then
    # Wait for the master hostname to be resolvable via Docker DNS
    MASTER_HOST="${SENTINEL_MASTER_HOST:-redis-master}"
    echo "Waiting for $MASTER_HOST to be resolvable..."
    while true; do
        MASTER_IP=$(getent hosts "$MASTER_HOST" 2>/dev/null | awk '{print $1}')
        [ -n "$MASTER_IP" ] && break
        sleep 1
    done
    echo "Resolved $MASTER_HOST -> $MASTER_IP"

    cat > "$CONFIG" <<EOF
port ${SENTINEL_PORT:-26379}
sentinel monitor mymaster ${MASTER_IP} ${SENTINEL_MASTER_PORT:-6379} ${SENTINEL_QUORUM:-1}
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 30000
sentinel parallel-syncs mymaster 1
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
EOF
    echo "Generated sentinel config:"
    cat "$CONFIG"
fi

exec redis-sentinel "$CONFIG"
