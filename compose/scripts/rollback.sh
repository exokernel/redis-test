#!/usr/bin/env bash
# Restore the cluster to Redis 6.2 from a saved AOF backup.
# Use after a failed upgrade where an 8.2 leader was elected.
#
# Steps:
#   1. Stop redis nodes (not sentinels — they stay running, as in production)
#   2. Clear redis-master and redis-replica-1 data volumes
#   3. Copy saved AOF into redis-master data volume
#   4. Start redis-master (6.2) and redis-replica-1 (6.2) — Redis loads AOF on startup
#   5. Reconfigure sentinels to track the restored master via SENTINEL REMOVE + MONITOR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

cd "$SCRIPT_DIR/.."

BACKUP_BASE="$SCRIPT_DIR/../backups"

header "Redis Rollback: Restore to Redis 6.2 from AOF"

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

if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#BACKUPS[@]}" ]; then
    echo "ERROR: Invalid selection '$sel'. Enter a number between 1 and ${#BACKUPS[@]}."
    exit 1
fi

BACKUP_DIR="$BACKUP_BASE/${BACKUPS[$((sel-1))]}"
BACKUP_AOF="$BACKUP_DIR/appendonly.aof"

if [ ! -f "$BACKUP_AOF" ]; then
    echo "ERROR: appendonly.aof not found in $BACKUP_DIR"
    exit 1
fi

echo ""
echo "Selected: $BACKUP_AOF"
echo ""
echo "This will:"
echo "  - Stop all Redis nodes (sentinels stay running)"
echo "  - Wipe redis-master and redis-replica-1 data volumes"
echo "  - Restore $BACKUP_AOF into redis-master"
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

# ── Restore AOF ───────────────────────────────────────────────────────────────
header "Restoring $BACKUP_AOF → redis-master..."

docker run --rm \
    -v "${PROJECT_NAME}_redis-master-data:/data" \
    -v "$BACKUP_DIR:/backup:ro" \
    redis:6.2 \
    sh -c "cp /backup/appendonly.aof /data/appendonly.aof && echo 'AOF copied.'"

# ── Start Redis 6.2 nodes ────────────────────────────────────────────────────
# Redis starts with appendonly=yes and finds appendonly.aof — loads it directly.
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
