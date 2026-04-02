.PHONY: up down reset status insert verify upgrade rollback backup connect

NAMESPACE := redis-test

# ── Cluster lifecycle ─────────────────────────────────────────────────────────

# Deploy Redis 8.2 with sentinel into the redis-test namespace.
# Services are applied before the StatefulSet (alphabetical order in manifests/)
# so pod DNS is available before pods start.
# --wait blocks until all pods report Ready (both containers per pod).
up:
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f manifests/
	kubectl rollout status statefulset/redis-node -n $(NAMESPACE) --timeout=120s

# Remove all manifests (stops pods, removes services and ConfigMap).
# PersistentVolumeClaims are NOT deleted — they're created by the StatefulSet
# controller outside of manifests/, so kubectl delete -f won't touch them.
# Run "make reset" to wipe everything including data.
down:
	kubectl delete -f manifests/ --ignore-not-found=true

# Full teardown: delete the entire namespace (removes everything, including PVCs).
reset:
	kubectl delete namespace $(NAMESPACE) 2>/dev/null || true

# ── Observability ─────────────────────────────────────────────────────────────

status:
	@bash scripts/status.sh

# ── Data ──────────────────────────────────────────────────────────────────────

# Insert 100 test keys (override: make insert COUNT=500)
insert:
	@bash scripts/insert-data.sh $(or $(COUNT),100)

verify:
	@bash scripts/verify-data.sh

# ── Upgrade / rollback ────────────────────────────────────────────────────────

# Snapshot the current master's RDB to backups/<timestamp>/dump.rdb.
# upgrade calls this automatically; run manually any time to take a checkpoint.
backup:
	@bash scripts/rdb-backup.sh

# Interactive upgrade walkthrough: 8.2 → 8.6 via rolling restart.
# Takes an RDB backup first, then patches the image.  Sentinel handles
# failover automatically mid-rollout.
upgrade:
	@bash scripts/upgrade.sh

# Roll back to Redis 8.2, restoring data from the pre-upgrade RDB backup.
#
# Downgrading Redis is not a simple image swap: Redis 8.6 writes RDB format
# version 13 which Redis 8.2 cannot read.  rdb-restore.sh handles this by
# scaling to 0, writing the backup RDB into node-0's PVC via a temporary pod,
# then scaling back up on redis:8.2.
rollback:
	@bash scripts/rdb-restore.sh

# ── Access ────────────────────────────────────────────────────────────────────

# Forward Redis and sentinel ports to localhost for manual redis-cli access.
# The ClusterIP service load-balances across both pods — use sentinel on :26379
# to discover the current master before sending writes.  Ctrl-C to stop.
connect:
	kubectl port-forward -n $(NAMESPACE) svc/redis 6379:6379 26379:26379
