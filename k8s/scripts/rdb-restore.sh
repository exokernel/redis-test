#!/usr/bin/env bash
# Restore a dump.rdb backup into the cluster and restart on Redis 8.2.
#
# Why this is more involved than the Compose rollback:
#   In Compose, redis-master is a dedicated container whose volume you can
#   write to directly while it's stopped.  In k8s, PVCs can only be mounted
#   by a running pod — so we spin up a temporary busybox pod that mounts
#   node-0's PVC, copy the RDB in via kubectl cp, then tear it down.
#
# Flow:
#   1. Scale StatefulSet to 0 (releases PVC mounts)
#   2. Spin up restore-helper pod mounting redis-data-redis-node-0
#   3. kubectl cp dump.rdb → /data/dump.rdb; wipe AOF files
#      (Redis 8.x uses a multi-file AOF format; stale AOF files would take
#       precedence over the RDB on startup — wiping them forces RDB load)
#   4. Delete restore-helper pod
#   5. Delete node-1 data PVC (will be recreated empty; node-1 full-syncs
#      from node-0 on startup, picking up the restored data)
#   6. Delete sentinel data PVCs (forces fresh sentinel config; avoids stale
#      master-address entries from the pre-rollback run)
#   7. Patch StatefulSet image to redis:8.2
#   8. Scale back to 2; node-0 loads RDB → becomes master; node-1 syncs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

LAST_BACKUP_FILE="$SCRIPT_DIR/../.last_backup"
TARGET_IMAGE="${1:-redis:8.2}"

# ── Resolve backup path ───────────────────────────────────────────────────────

if [ -n "${2:-}" ]; then
    BACKUP_DIR="$2"
elif [ -f "$LAST_BACKUP_FILE" ]; then
    BACKUP_DIR=$(cat "$LAST_BACKUP_FILE")
else
    echo "ERROR: no backup path given and $LAST_BACKUP_FILE not found." >&2
    echo "Usage: $0 [target-image] [backup-dir]" >&2
    echo "  e.g. $0 redis:8.2 k8s/backups/20260401-120000" >&2
    exit 1
fi

BACKUP_RDB="$BACKUP_DIR/dump.rdb"
if [ ! -f "$BACKUP_RDB" ]; then
    echo "ERROR: backup file not found: $BACKUP_RDB" >&2
    exit 1
fi

echo "Restoring from: $BACKUP_RDB"
echo "Target image:   $TARGET_IMAGE"
echo ""

# ── Scale down ────────────────────────────────────────────────────────────────

header "Scaling down StatefulSet"
kubectl scale statefulset/redis-node --replicas=0 -n "$NAMESPACE"
echo "Waiting for pods to terminate..."
kubectl wait --for=delete pod/redis-node-0 pod/redis-node-1 \
    -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

# ── Restore node-0 data PVC via temporary pod ─────────────────────────────────
#
# A PVC with accessMode ReadWriteOnce can only be mounted while no other pod
# holds it.  With the StatefulSet scaled to 0 the PVC is free, so we mount it
# in a temporary pod just long enough to restore the data.
#
# Why redis:8.2 and not busybox:
#   Redis with appendonly=yes ignores dump.rdb on startup when no AOF exists
#   — it creates a fresh empty AOF instead.  The fix (same as compose/rollback.sh)
#   is to start a temporary redis-server with --appendonly no so it loads the
#   RDB, then CONFIG SET appendonly yes + BGREWRITEAOF to write a populated AOF.
#   When the real StatefulSet pods start they find the AOF and load the data.

header "Restoring data to node-0 PVC"

HELPER_POD="redis-restore-helper"

TMPSPEC=$(mktemp /tmp/redis-restore-helper-XXXX.yaml)
cat > "$TMPSPEC" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: helper
    image: redis:8.2
    command: ["sleep", "300"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: redis-data-redis-node-0
EOF

kubectl apply -f "$TMPSPEC"
rm -f "$TMPSPEC"

echo "Waiting for restore-helper pod to be ready..."
kubectl wait --for=condition=Ready "pod/$HELPER_POD" \
    -n "$NAMESPACE" --timeout=30s

echo "Clearing stale data files on node-0 PVC..."
kubectl exec -n "$NAMESPACE" "$HELPER_POD" -- sh -c 'rm -rf /data/*'

echo "Copying $BACKUP_RDB → node-0:/data/dump.rdb..."
kubectl cp "$BACKUP_RDB" "${NAMESPACE}/${HELPER_POD}:/data/dump.rdb"

# Start redis with appendonly disabled so it loads dump.rdb, then enable AOF
# and trigger a rewrite.  The resulting appendonlydir contains the full dataset.
# Use port 7379 to avoid conflicting with any other process on 6379.
echo "Loading RDB and generating AOF..."
kubectl exec -n "$NAMESPACE" "$HELPER_POD" -- sh -c '
    redis-server --appendonly no --dir /data --port 7379 &
    RPID=$!
    until redis-cli -p 7379 ping 2>/dev/null | grep -q PONG; do sleep 1; done
    redis-cli -p 7379 CONFIG SET appendonly yes
    redis-cli -p 7379 BGREWRITEAOF
    while true; do
        STATUS=$(redis-cli -p 7379 info persistence | grep aof_rewrite_in_progress | tr -d "\r" | cut -d: -f2)
        [ "$STATUS" = "0" ] && break
        sleep 1
    done
    redis-cli -p 7379 SHUTDOWN NOSAVE || true
    wait $RPID || true
'

echo "Deleting restore-helper pod..."
kubectl delete pod "$HELPER_POD" -n "$NAMESPACE" --ignore-not-found=true

# ── Delete node-1 data PVC ────────────────────────────────────────────────────
# Node-1 will start empty and do a full sync from node-0, picking up the
# restored dataset.  Faster and simpler than restoring into node-1 too.

header "Clearing node-1 data PVC"
kubectl delete pvc redis-data-redis-node-1 \
    -n "$NAMESPACE" --ignore-not-found=true

# ── Delete sentinel data PVCs ─────────────────────────────────────────────────
# Sentinel config on each PVC tracks the current master address.  After a
# failover during the upgrade the config may point to a pod that is no longer
# master after restore.  Wiping sentinel PVCs forces fresh config generation.

header "Clearing sentinel PVCs"
kubectl delete pvc \
    sentinel-data-redis-node-0 \
    sentinel-data-redis-node-1 \
    -n "$NAMESPACE" --ignore-not-found=true

# ── Patch image and scale up ──────────────────────────────────────────────────

header "Starting cluster on $TARGET_IMAGE"
kubectl set image statefulset/redis-node \
    redis="$TARGET_IMAGE" sentinel="$TARGET_IMAGE" \
    -n "$NAMESPACE"
kubectl scale statefulset/redis-node --replicas=2 -n "$NAMESPACE"
kubectl rollout status statefulset/redis-node -n "$NAMESPACE" --timeout=120s

echo ""
echo "Restore complete. Run 'make verify' to confirm data integrity."
