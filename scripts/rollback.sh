#!/usr/bin/env bash
# Restore the cluster to Redis 6.2 from a saved RDB backup.
# Use after a failed upgrade where an 8.2 leader was elected.
#
# Steps:
#   1. Stop all containers (including any 8.2 nodes)
#   2. Clear redis-master and redis-replica-1 data volumes
#   3. Restore selected dump.rdb into redis-master volume (no AOF, so Redis loads RDB)
#   4. Start redis-master (6.2), redis-replica-1 (6.2), and sentinels
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
echo "  - Stop ALL redis containers (including any running 8.2 nodes)"
echo "  - Wipe redis-master and redis-replica-1 data volumes"
echo "  - Restore $BACKUP_RDB into redis-master"
echo "  - Restart the Redis 6.2 cluster (master + replica-1 + sentinels)"
echo ""
confirm "Proceed with rollback?"

# ── Stop all containers ───────────────────────────────────────────────────────
header "Stopping all containers..."
docker-compose --profile v82 down 2>/dev/null || docker-compose down

# ── Wipe data volumes (redis-master and redis-replica-1) ─────────────────────
header "Clearing data volumes..."

for vol in "${PROJECT_NAME}_redis-master-data" "${PROJECT_NAME}_redis-replica-1-data"; do
    echo "  Clearing $vol..."
    docker run --rm -v "${vol}:/data" redis:6.2 \
        sh -c "rm -f /data/dump.rdb /data/appendonly.aof /data/appendonly.aof.manifest && echo '  Done.'"
done

# ── Clear sentinel configs so they re-generate pointing to redis-master ───────
header "Clearing sentinel config volumes..."

for vol in "${PROJECT_NAME}_sentinel-1-data" "${PROJECT_NAME}_sentinel-2-data"; do
    docker run --rm -v "${vol}:/sentinel-data" redis:6.2 \
        sh -c "rm -f /sentinel-data/sentinel.conf && echo '  Cleared.'"
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
    --network "${PROJECT_NAME}_redis-net" 2>/dev/null \
    -v "${PROJECT_NAME}_redis-master-data:/data" \
    -v "$(pwd)/config/redis.conf:/config/redis.conf:ro" \
    -p 6379:6379 \
    redis:6.2 \
    redis-server /config/redis.conf --appendonly no || \
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

# ── Start Redis 6.2 cluster ───────────────────────────────────────────────────
header "Starting Redis 6.2 cluster..."
docker-compose up -d redis-master redis-replica-1 sentinel-1 sentinel-2

echo ""
echo "Waiting 15s for cluster to settle..."
sleep 15
"$SCRIPT_DIR/status.sh"

header "Rollback Complete"
echo ""
echo "Run 'make verify' to confirm data integrity."
echo "Note: writes made after the backup snapshot are NOT present."
