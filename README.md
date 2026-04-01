# redis-test

Docker Compose environment for testing a Redis 6.2 → 8.2 upgrade using the "new nodes" strategy (Option A), with Redis Sentinel managing failover.

## Architecture

```
redis-master (6.2)   ←── replication ──→   redis-replica-1 (6.2)
        ↑
  sentinel-1  sentinel-2   (quorum = 1)

# Option A upgrade adds:
redis-replica-2 (8.2)
redis-replica-3 (8.2)
```

Sentinel ports: `26379`, `26380`  
Redis ports: master=`6379`, replica-1=`6380`, replica-2=`6381`, replica-3=`6382`

## Volumes

| Volume | Type | Contents |
|---|---|---|
| `redis-test_redis-master-data` | Docker-managed | RDB + AOF for master |
| `redis-test_redis-replica-{1,2,3}-data` | Docker-managed | RDB + AOF per replica |
| `redis-test_sentinel-{1,2}-data` | Docker-managed | Sentinel config (rewritten on failover) |
| `./config/redis.conf` | Bind mount (read-only) | Shared Redis config for all nodes |
| `./config/sentinel-entrypoint.sh` | Bind mount (read-only) | Generates sentinel config on first boot |

Sentinel config is generated from env vars on first boot and persisted to its volume so post-failover topology survives container restarts.

## Commands

| Command | Description |
|---|---|
| `make up` | Start 6.2 cluster (master + replica + 2 sentinels) |
| `make down` | Stop all containers (preserves volumes) |
| `make reset` | Stop all containers and **delete all volumes** — full clean slate |
| `make status` | Show topology, roles, versions, replication lag |
| `make logs` | Tail logs from all containers |
| `make insert` | Write 100 test keys (`make insert COUNT=500` to override) |
| `make verify` | Assert all inserted keys are present with correct values |
| `make backup` | BGSAVE on current master + copy `dump.rdb` to `./backups/<timestamp>/` |
| `make upgrade` | Interactive Option A upgrade walkthrough |
| `make rollback` | Restore cluster to Redis 6.2 from a saved RDB backup |

## Typical test flows

### Test upgrade (no rollback)

```bash
make up
make insert
make verify        # establish baseline
make backup        # snapshot before upgrade
make upgrade       # interactive — pauses at each step
make verify        # confirm no data loss
make reset         # clean up
```

### Test rollback

```bash
make up
make insert
make verify
make backup
make upgrade       # proceed through all steps including failover
# --- do NOT run 'make verify' yet ---
make rollback      # select the backup taken before failover
make verify        # confirm data restored to pre-failover state
make reset
```

`make rollback` is interactive — it lists available backups and asks you to confirm before making changes.

### Inspect the cluster manually

```bash
# Current master (from sentinel)
redis-cli -p 26379 sentinel get-master-addr-by-name mymaster

# Replication info from master
redis-cli -p 6379 info replication

# NOTE: KEYS is renamed — use SCAN instead
redis-cli -p 6379 --scan --pattern "testkey:*"
```

## Rollback details

### What rollback does

1. Stops all containers (including any running 8.2 nodes)
2. Wipes the `redis-master` and `redis-replica-1` data volumes
3. Copies the selected `dump.rdb` into the `redis-master` volume
4. Boots a **temporary** Redis 6.2 container with `appendonly no` to load the RDB — this is necessary because Redis 6.2 with `appendonly yes` will not load an RDB when no AOF file is present; it just starts empty
5. Enables AOF and runs `BGREWRITEAOF` to persist the dataset as an AOF, then shuts down the temp container
6. Starts the normal 6.2 cluster (master + replica-1 + sentinels) — Redis now loads from the AOF generated in step 5
7. Sentinel config volumes are cleared so sentinels re-generate pointing back to `redis-master`

### Rollback caveats

- **Data loss is expected.** Any writes after the `make backup` snapshot are not in the RDB and will not be present after rollback. Production RDB cadence is every 15 minutes, so up to 15 minutes of writes could be lost.
- **The backup must be taken before the failover** (Step 4 of the upgrade script does this automatically). A backup taken from a 6.2 node after an 8.2 node has been promoted as master is not usable for downgrade — the RDB format may contain 8.2-specific encodings that 6.2 cannot read.
- **`make clean` removes all saved backups.** `make reset` also does this. Do not reset until you are sure rollback is no longer needed.

### Production rollback notes

In production, the equivalent steps are:
1. Stop the 8.2 master (prevent further writes)
2. Provision a Redis 6.2 node (or downgrade an existing node before it ever replicated from an 8.2 master)
3. Copy the pre-failover `dump.rdb` to the node's data directory
4. Start Redis 6.2 with `appendonly no`, verify data loaded, then enable `appendonly yes` and run `BGREWRITEAOF`
5. Update sentinel to monitor the restored 6.2 node

## Notes

- **`KEYS` is disabled** in `redis.conf` (`rename-command KEYS KEYS-DONOTEXECUTEINPROD`). All scripts use `--scan`. If you need `KEYS` in a manual `redis-cli` session, use `KEYS-DONOTEXECUTEINPROD`.
- **`redis:8.2` image** — verify the tag exists on Docker Hub. Substitute `redis:8` or the latest stable tag if needed.
- **Sentinel TILT mode** — Docker Desktop on macOS has imprecise container timers that continuously trigger sentinel TILT mode, which blocks sentinel-driven failovers. The upgrade script uses `REPLICAOF NO ONE` (manual promotion) to work around this. On real Linux servers, sentinel failover works normally. In production, use `sentinel failover mymaster`.
