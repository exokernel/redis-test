#!/usr/bin/env bash
# Interactive walkthrough of Option A: build new Redis 8.2 nodes, failover, remove 6.2 nodes.
#
# Expected start state:  1x Redis 6.2 master (redis-master)
#                        1x Redis 6.2 replica (redis-replica-1)
#                        2x Sentinel
#
# Expected end state:    1x Redis 8.2 master
#                        1x Redis 8.2 replica
#                        2x Sentinel
#
# NOTE: Uses manual REPLICAOF NO ONE promotion instead of sentinel failover.
#       Docker Desktop's timer inaccuracy causes sentinel TILT mode, blocking
#       sentinel-driven failovers. On real servers, use "sentinel failover mymaster".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

cd "$SCRIPT_DIR/.."   # run compose from project root

# The 8.2 replica we'll promote to master
PROMOTE_TARGET="redis-replica-2"
PROMOTE_PORT=6381
OTHER_REPLICA="redis-replica-3"
OTHER_PORT=6382

header "Option A: Redis 6.2 → 8.2 Upgrade (New Nodes)"
echo ""
echo "This script walks through each step and pauses for confirmation."
echo "Run 'make verify' at the end to confirm data integrity."

# ── Step 1: Baseline ──────────────────────────────────────────────────────────
header "Step 1/7 — Current state"
"$SCRIPT_DIR/status.sh"
confirm "Ready to begin upgrade?"

# ── Step 2: Bring up 8.2 replicas ────────────────────────────────────────────
header "Step 2/7 — Start Redis 8.2 replicas"
echo "Bringing up redis-replica-2 and redis-replica-3 (Redis 8.2)..."
docker-compose --profile v82 up -d redis-replica-2 redis-replica-3

echo ""
echo "Waiting for containers to start and sync..."
sleep 10

echo ""
echo "State: 1x6.2 Master, 1x6.2 Replica, 2x8.2 Replicas"
"$SCRIPT_DIR/status.sh"
echo ""
echo "Wait until replication lag is 0 for both 8.2 replicas before continuing."
confirm "Replication caught up? Continue?"

# ── Step 3: Remove 6.2 replica ───────────────────────────────────────────────
header "Step 3/7 — Remove Redis 6.2 replica (redis-replica-1)"
echo "State after: 1x6.2 Master, 2x8.2 Replicas"
confirm "Stop and remove redis-replica-1?"

docker-compose stop redis-replica-1
docker-compose rm -f redis-replica-1

sleep 3
"$SCRIPT_DIR/status.sh"
confirm "State looks good? Continue?"

# ── Step 4: RDB backup ────────────────────────────────────────────────────────
header "Step 4/7 — RDB backup (pre-failover safety net)"
echo "Taking BGSAVE snapshot of the current 6.2 master..."
"$SCRIPT_DIR/rdb-backup.sh"
BACKUP_PATH=$(cat "$SCRIPT_DIR/../.last_backup")
echo ""
echo "Backup written to: $BACKUP_PATH"
confirm "Backup complete. Continue to point of no return?"

# ── Step 5: Promote 8.2 replica ──────────────────────────────────────────────
header "Step 5/7 — [POINT OF NO RETURN] Promote $PROMOTE_TARGET to master"
echo ""
echo "  WARNING: After this step, rolling back requires restoring from RDB."
echo "           Any writes after the BGSAVE snapshot will be lost on rollback."
echo ""
echo "  Current backup: $BACKUP_PATH"
echo ""
echo "  Promoting: $PROMOTE_TARGET (localhost:$PROMOTE_PORT)"
echo "  Method:    REPLICAOF NO ONE (manual promotion)"
echo ""
echo "  NOTE: In production, use 'sentinel failover mymaster'."
echo "        Manual promotion is used here because Docker Desktop's timer"
echo "        issues cause sentinel TILT mode."
echo ""
confirm "CONFIRM: Promote $PROMOTE_TARGET to master?"

# Promote the target replica
echo "Running: REPLICAOF NO ONE on $PROMOTE_TARGET..."
redis-cli -p "$PROMOTE_PORT" REPLICAOF NO ONE

# Wait for promotion to take effect
sleep 2
ROLE=$(redis-cli -p "$PROMOTE_PORT" info replication | grep "^role:" | tr -d '\r' | cut -d: -f2)
if [ "$ROLE" != "master" ]; then
    echo "ERROR: $PROMOTE_TARGET role is '$ROLE', expected 'master'. Aborting."
    exit 1
fi
echo "$PROMOTE_TARGET is now master."

# Point the other 8.2 replica at the new master
NEW_MASTER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PROMOTE_TARGET")
echo "Reconfiguring $OTHER_REPLICA to replicate from $PROMOTE_TARGET ($NEW_MASTER_IP)..."
redis-cli -p "$OTHER_PORT" REPLICAOF "$NEW_MASTER_IP" 6379

sleep 3
"$SCRIPT_DIR/status.sh"

echo ""
echo "New master: $PROMOTE_TARGET (Redis 8.2)"
confirm "Promotion complete. Continue to reconfigure sentinels?"

# ── Step 6: Reconfigure sentinel ──────────────────────────────────────────────
header "Step 6/7 — Reset sentinel to track new master"
echo "Removing old master definition and re-registering with new master IP ($NEW_MASTER_IP)..."
echo ""
echo "  In production with working sentinel (no TILT), you could use:"
echo "    sentinel reset mymaster   (on each sentinel, 30s apart)"
echo "  Here we use REMOVE + MONITOR to be explicit about the new master."
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
sleep 10

"$SCRIPT_DIR/status.sh"
confirm "Sentinels reconfigured. Continue to remove old 6.2 master?"

# ── Step 7: Remove 6.2 master ────────────────────────────────────────────────
header "Step 7/7 — Remove former Redis 6.2 master (redis-master)"
echo "The former master cannot replicate from an 8.2 node."
echo "Stopping it now."
confirm "Stop and remove redis-master?"

docker-compose stop redis-master
docker-compose rm -f redis-master

sleep 3

header "Upgrade Complete"
"$SCRIPT_DIR/status.sh"
echo ""
echo "Target state reached: 1x Redis 8.2 Master, 1x Redis 8.2 Replica"
echo ""
echo "Run 'make verify' to confirm no data was lost."
