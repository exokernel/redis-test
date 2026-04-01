#!/usr/bin/env bash
# Restore the cluster to Redis 6.2 from a saved RDB backup.
# Use after a failed upgrade where an 8.2 leader was elected.
#
# Steps:
#   1. Stop redis nodes (not sentinels — they stay running, as in production)
#   2. Clear redis-master and redis-replica-1 data volumes
#   3. Restore selected dump.rdb, boot temp Redis to generate AOF
#   4. Start redis-master (6.2) and redis-replica-1 (6.2)
#   5. Reconfigure sentinels to track the restored master via SENTINEL REMOVE + MONITOR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

cd "$SCRIPT_DIR/.."

BACKUP_BASE="$SCRIPT_DIR/../backups"

header "Redis Rollback: Restore to Redis 6.2 from RDB"

# ── Select backup ─────────────────────────────────────────────────────────────
if [ ! -d "$BACKUP_BASE" ] || [ -z "$(ls -A "$BACKUP_BASE" 2>/dev/null)" ]; then
    echo "ERROR: No backups found in $BACKUP_BASE"
    echo "       Run 'make backup' before the upgrade next time."
    exit 1
fi

echo ""
echo "Available backups (newest first):"
echo ""

BACKUPS=($(ls -t "$BACKUP_BASE"))
for i in "${!BACKUPS[@]}"; do
    echo "  $((i+1))) ${BACKUPS[$i]}"
done
echo ""
echo -n "Select backup [1]: "
read -r sel
sel="${sel:-1}"

BACKUP_DIR="$BACKUP_BASE/${BACKUPS[$((sel-1))]}"
BACKUP_RDB="$BACKUP_DIR/dump.rdb"

if [ ! -f "$BACKUP_RDB" ]; then
    echo "ERROR: dump.rdb not found in $BACKUP_DIR"
    exit 1
fi

echo ""
echo "Selected: $BACKUP_RDB"
echo ""
echo "This will:"
echo "  - Stop all Redis nodes (sentinels stay running)"
echo "  - Wipe redis-master and redis-replica-1 data volumes"
echo "  - Restore $BACKUP_RDB into redis-master"
echo "  - Start redis-master (6.2) and redis-replica-1 (6.2)"
echo "  - Reconfigure sentinels to track the restored master"
echo ""
confirm "Proceed with rollback?"

# ── Stop redis nodes (not sentinels) ─────────────────────────────────────────
header "Stopping Redis nodes..."
# Stop 8.2 nodes if running
docker-compose --profile v82 stop redis-replica-2 redis-replica-3 2>/dev/null || true
docker-compose --profile v82 rm -f redis-replica-2 redis-replica-3 2>/dev/null || true
# Stop 6.2 nodes if running
docker-compose stop redis-master redis-replica-1 2>/dev/null || true
docker-compose rm -f redis-master redis-replica-1 2>/dev/null || true

# ── Wipe data volumes (redis-master and redis-replica-1) ─────────────────────
header "Clearing data volumes..."

for vol in "${PROJECT_NAME}_redis-master-data" "${PROJECT_NAME}_redis-replica-1-data"; do
    echo "  Clearing $vol..."
    docker run --rm -v "${vol}:/data" redis:6.2 \
        sh -c "rm -f /data/dump.rdb /data/appendonly.aof /data/appendonly.aof.manifest && echo '  Done.'"
done

# ── Restore RDB and generate AOF ─────────────────────────────────────────────
# Redis 6.2 with appendonly=yes ignores the RDB when no AOF exists — it starts
# empty. We work around this by booting a temp container with appendonly=no
# (which loads the RDB), then enabling AOF and triggering a rewrite so the data
# is persisted in AOF format for the real startup.
header "Restoring $BACKUP_RDB → redis-master..."

docker run --rm \
    -v "${PROJECT_NAME}_redis-master-data:/data" \
    -v "$(cd "$(dirname "$BACKUP_RDB")" && pwd):/backup:ro" \
    redis:6.2 \
    sh -c "cp /backup/dump.rdb /data/dump.rdb && echo 'RDB copied.'"

echo "Starting temp Redis to load RDB and generate AOF..."
docker run --rm -d --name redis-restore \
    -v "${PROJECT_NAME}_redis-master-data:/data" \
    -v "$(pwd)/config/redis.conf:/config/redis.conf:ro" \
    -p 6379:6379 \
    redis:6.2 \
    redis-server /config/redis.conf --appendonly no

echo "Waiting for RDB load..."
sleep 3

KEY_COUNT=$(redis-cli -p 6379 --scan --pattern "testkey:*" | wc -l | tr -d ' ')
echo "Keys loaded from RDB: $KEY_COUNT"

echo "Enabling AOF and triggering rewrite..."
redis-cli -p 6379 CONFIG SET appendonly yes > /dev/null
redis-cli -p 6379 BGREWRITEAOF > /dev/null

echo -n "Waiting for AOF rewrite to complete"
while true; do
    REWRITING=$(redis-cli -p 6379 info persistence 2>/dev/null | grep "^aof_rewrite_in_progress:" | tr -d '\r' | cut -d: -f2)
    [ "$REWRITING" = "0" ] && break
    echo -n "."
    sleep 1
done
echo " done."

docker stop redis-restore > /dev/null

# ── Start Redis 6.2 nodes ────────────────────────────────────────────────────
header "Starting Redis 6.2 nodes..."
docker-compose up -d redis-master redis-replica-1

echo ""
echo "Waiting 10s for replication to sync..."
sleep 10

# ── Reconfigure sentinels to track restored master ───────────────────────────
header "Reconfiguring sentinels to track restored master..."

NEW_MASTER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' redis-master)
echo "Restored master IP: $NEW_MASTER_IP"
echo ""

for port in "$SENTINEL_PORT_1" "$SENTINEL_PORT_2"; do
    echo "Sentinel on port $port:"
    redis-cli -p "$port" SENTINEL REMOVE mymaster 2>/dev/null || true
    redis-cli -p "$port" SENTINEL MONITOR mymaster "$NEW_MASTER_IP" 6379 1
    redis-cli -p "$port" SENTINEL SET mymaster down-after-milliseconds 5000
    redis-cli -p "$port" SENTINEL SET mymaster failover-timeout 30000
    redis-cli -p "$port" SENTINEL SET mymaster parallel-syncs 1
    echo ""
done

echo "Waiting for sentinels to discover replicas..."
sleep 5
"$SCRIPT_DIR/status.sh"

header "Rollback Complete"
echo ""
echo "Run 'make verify' to confirm data integrity."
echo "Note: writes made after the backup snapshot are NOT present."
