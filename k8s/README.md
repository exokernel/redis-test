# Redis upgrade test — Kubernetes environment

Kubernetes version of the Redis 8.2 → 8.6 upgrade test, using raw k8s manifests
and the official `redis` Docker image.

The upgrade procedure mirrors what Kubernetes and Sentinel do automatically:
instead of manually orchestrating new nodes and reconfiguring sentinels (the
Compose "Option A" approach), a single `kubectl set image` command triggers a
**rolling restart** that Sentinel handles transparently.

## Prerequisites

- [k3d](https://k3d.io) — runs a k3s cluster in Docker containers on your laptop
- [kubectl](https://kubernetes.io/docs/tasks/tools/) — Kubernetes CLI

Check you have everything:

```bash
k3d version
kubectl version --client
```

## First-time setup

Create a k3d cluster if you don't have one already:

```bash
k3d cluster create redis-test
```

k3d automatically updates `~/.kube/config` so `kubectl` points at the new
cluster. Verify:

```bash
kubectl get nodes
```

## Architecture

```
Namespace: redis-test

  Pod: redis-node-0              Pod: redis-node-1
  ┌─────────────────────┐        ┌─────────────────────┐
  │ container: redis    │  ←──   │ container: redis    │
  │ container: sentinel │        │ container: sentinel │
  └─────────────────────┘        └─────────────────────┘
         │                              │
  PVC: redis-data-redis-node-0   PVC: redis-data-redis-node-1
  PVC: sentinel-data-redis-node-0 PVC: sentinel-data-redis-node-1

  Service: redis-headless  (clusterIP: None — stable pod DNS)
  Service: redis           (ClusterIP — port-forward / client access)
```

**StatefulSet** gives each pod a stable name (`redis-node-0`, `redis-node-1`)
and stable storage (one PVC per pod per `volumeClaimTemplate`). Pod identity
matters for Redis: a restarted pod finds its own data and resumes replication.

**Pod-0 is the initial master.** The startup command checks `$MY_POD_NAME` and
omits `--replicaof` for pod-0. After any failover, Sentinel elects the surviving
pod as master regardless of ordinal — either pod can be master at any time.

**Key differences from Docker Compose:**

| | Docker Compose | Kubernetes |
|---|---|---|
| Sentinel | 2 separate containers | Sidecar in every Redis pod |
| Master/replica | Fixed container names | Sentinel-elected at runtime |
| External access | Host ports (`-p`) | `kubectl port-forward` |
| Upgrade | Manual step-by-step script | `kubectl set image` → rolling restart |
| Rollback | RDB restore surgery | RDB restore via helper pod → rolling restart |

## Commands

| Command | Description |
|---|---|
| `make up` | Deploy Redis 8.2 cluster (blocks until Ready) |
| `make down` | Remove manifests (keeps PVCs / data) |
| `make reset` | Delete the entire namespace — full clean slate |
| `make status` | Show pods, sentinel state, roles, versions |
| `make insert` | Write 100 test keys (`make insert COUNT=500` to override) |
| `make verify` | Assert all inserted keys are present with correct values |
| `make backup` | Snapshot current master RDB to `backups/<timestamp>/dump.rdb` |
| `make upgrade` | Backup → patch to 8.6 → rolling restart (sentinel handles failover) |
| `make rollback` | Restore RDB backup → restart on 8.2 |
| `make connect` | Port-forward Redis+sentinel to localhost for `redis-cli` |

## Typical test flow

```bash
# 1. Bring up the cluster
make up

# 2. Confirm it's healthy — look for 2/2 Ready pods
make status

# 3. Seed test data
make insert
make verify    # establish baseline

# 4. Upgrade
make upgrade   # explains what will happen, asks to confirm

# 5. Confirm no data loss
make verify

# 6. Clean up
make reset
```

## How the upgrade works

`make upgrade` patches the StatefulSet image tag with `kubectl set image`.
Kubernetes performs a **rolling restart**, highest ordinal first:

1. `redis-node-1` (replica) is restarted on `redis:8.6`
2. `redis-node-0` (master) is restarted
   → Sentinel detects it going down, promotes `redis-node-1` to master
3. `redis-node-0` comes back on `redis:8.6` and rejoins as a replica

The Sentinel failover happens mid-rollout, automatically, with no manual
intervention. This replaces the entire Option A script from the Compose
environment.

**Downtime:** reads are zero-downtime throughout. Writes have a ~5 second gap
while sentinel detects the master is down and promotes node-1 (`down-after-milliseconds`).
Redis client libraries with retry logic (Lettuce, StackExchange.Redis) handle
this transparently.

During the rollout, watch progress in another terminal:

```bash
kubectl get pods -n redis-test -w
```

## How rollback works

```bash
make rollback
```

Rolling back Redis is not a simple image swap. Redis 8.6 writes RDB format
version 13 which Redis 8.2 cannot read, so a rolling restart would leave each
pod crashlooping as it tries to load 8.6-format data.

`make rollback` handles this by:

1. Scaling the StatefulSet to 0 (brief full outage — this is not zero-downtime)
2. Spinning up a temporary `redis:8.2` helper pod mounting node-0's PVC
3. Copying the pre-upgrade backup RDB into `/data/`
4. Starting a temporary redis-server with `--appendonly no` to load the RDB,
   then `CONFIG SET appendonly yes` + `BGREWRITEAOF` to generate a valid AOF
   (Redis ignores `dump.rdb` on startup when `appendonly yes` and no AOF exists)
5. Scaling back up — node-0 loads the restored AOF, node-1 syncs from it

Data written after the backup snapshot is lost. Run `make verify` afterwards.

## Manual inspection

```bash
# Watch pods in real time
kubectl get pods -n redis-test -w

# Ask sentinel who the current master is
kubectl exec -n redis-test redis-node-0 -c sentinel -- \
    redis-cli -p 26379 sentinel get-master-addr-by-name mymaster

# Replication info from a specific pod
kubectl exec -n redis-test redis-node-0 -c redis -- redis-cli info replication

# Logs from a specific container
kubectl logs -n redis-test redis-node-0 -c redis
kubectl logs -n redis-test redis-node-0 -c sentinel

# Drop into a shell inside a pod
kubectl exec -it -n redis-test redis-node-0 -c redis -- sh

# Connect from your laptop via port-forward (Ctrl-C to stop)
make connect
redis-cli -p 6379 ping
redis-cli -p 26379 sentinel masters
```

## Notes

- **`make down` keeps data.** PVCs are created by the StatefulSet controller
  and are not listed in `manifests/`, so `kubectl delete -f manifests/` does
  not touch them. `make reset` (deletes the namespace) is the full wipe.
- **`KEYS` is disabled** in the Redis config (same as Compose). Use `--scan`
  or `KEYS-DONOTEXECUTEINPROD`.
- **k3d storage.** k3d's default StorageClass (`local-path`) backs PVCs with
  directories on the Docker host VM. Data persists across pod restarts but is
  lost if you delete the cluster (`k3d cluster delete redis-test`).
- **Sentinel config persistence.** Each pod's sentinel writes its config to
  `/sentinel-data/sentinel.conf` on its own PVC. The config is preserved across
  pod restarts and contains the current master address after any failover.
