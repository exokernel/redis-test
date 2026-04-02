#!/usr/bin/env bash
# Upgrade Redis 8.2 → 8.6 by patching the StatefulSet image.
#
# How this compares to the Docker Compose "Option A" procedure:
#
#   Compose (manual):
#     1. Bring up new 8.2 pods as replicas
#     2. Wait for replication to catch up
#     3. Manually REPLICAOF NO ONE to promote one
#     4. Reconfigure sentinels via SENTINEL REMOVE + MONITOR
#     5. Remove old pods
#
#   k8s (automatic):
#     1. Patch the StatefulSet image tag (kubectl set image)
#     2. k8s restarts redis-node-1 (replica) on redis:8.6 first
#     3. k8s restarts redis-node-0 (master) — sentinel detects it is down and
#        elects redis-node-1 as new master automatically
#     4. redis-node-0 comes back on redis:8.6 and rejoins as replica
#
#   The entire manual procedure is replaced by two k8s primitives:
#     - StatefulSet rolling update  (orchestrates the restart order)
#     - Sentinel failover           (handles master promotion mid-rollout)
#
# Rollback: make rollback  (patches image back to redis:8.2, same mechanism)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

FROM_VERSION="8.2"
TO_VERSION="8.6"

header "Redis Upgrade: ${FROM_VERSION} → ${TO_VERSION}"

echo ""
echo "Current state:"
"$SCRIPT_DIR/status.sh"

echo ""
echo "What will happen:"
echo "  1. StatefulSet image patched: redis:${FROM_VERSION} → redis:${TO_VERSION}"
echo "  2. k8s restarts redis-node-1 (replica) on the new image first"
echo "  3. k8s restarts redis-node-0 (master)"
echo "     → sentinel detects master down, promotes node-1 to master"
echo "     → node-0 restarts on redis:${TO_VERSION}, rejoins as replica"
echo "  4. Cluster is fully on redis:${TO_VERSION} — no manual failover steps"
echo ""
echo "To rollback afterwards: make rollback"
echo ""
echo -n "Continue? [y/N] "
read -r ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

echo ""
header "Taking pre-upgrade RDB backup"
bash "$SCRIPT_DIR/rdb-backup.sh"

echo ""
echo "Patching StatefulSet image..."

kubectl set image statefulset/redis-node \
    redis=redis:${TO_VERSION} sentinel=redis:${TO_VERSION} \
    -n "$NAMESPACE"

echo ""
echo "Watching rollout (Ctrl-C to detach — rollout continues in background)..."
kubectl rollout status statefulset/redis-node -n "$NAMESPACE" --timeout=5m

echo ""
echo "Upgrade complete. Final state:"
"$SCRIPT_DIR/status.sh"

echo ""
echo "Run 'make verify' to confirm no data was lost."
echo ""
echo "To rollback: make rollback"
echo "  (patches image back to redis:${FROM_VERSION}, triggers another rolling restart)"
