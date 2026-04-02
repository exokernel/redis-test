#!/usr/bin/env bash
# Trigger BGSAVE on the current sentinel-elected master, wait for it to
# complete, then kubectl cp dump.rdb to ./backups/<timestamp>/dump.rdb.
#
# Equivalent to compose/scripts/rdb-backup.sh but uses kubectl cp instead
# of docker cp.  The RDB file path inside the pod is /data/dump.rdb,
# written by redis-server per the "dir /data" + "dbfilename dump.rdb"
# settings in redis.conf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

BACKUP_BASE="$SCRIPT_DIR/../backups"
LAST_BACKUP_FILE="$SCRIPT_DIR/../.last_backup"

MASTER_POD=$(get_master_pod)
echo "Master pod: $MASTER_POD"

# Trigger a background RDB save.  BGSAVE forks; the save happens asynchronously.
echo "Triggering BGSAVE..."
master_cli BGSAVE > /dev/null

# Poll rdb_bgsave_in_progress rather than LASTSAVE.
# LASTSAVE is a Unix timestamp (1-second resolution) — for small datasets
# BGSAVE completes in the same second as the previous save, so LASTSAVE never
# changes and a LASTSAVE-based loop spins forever.
# rdb_bgsave_in_progress drops to 0 the moment the fork finishes, regardless
# of wall-clock time, so it handles both instant and slow saves correctly.
echo -n "Waiting for BGSAVE to complete"
while true; do
    IN_PROGRESS=$(master_cli INFO persistence 2>/dev/null \
        | grep rdb_bgsave_in_progress | tr -d '\r' | cut -d: -f2)
    [ "$IN_PROGRESS" = "0" ] && break
    echo -n "."
    sleep 1
done
echo " done."

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEST="$BACKUP_BASE/$TIMESTAMP"
mkdir -p "$DEST"

# kubectl cp streams the file through the API server — no host port required.
# Equivalent to "docker cp <container>:/data/dump.rdb <dest>" in Compose.
echo "Copying dump.rdb from $MASTER_POD:/data/dump.rdb..."
kubectl cp "${NAMESPACE}/${MASTER_POD}:/data/dump.rdb" "$DEST/dump.rdb" -c redis

echo "$DEST" > "$LAST_BACKUP_FILE"
echo "Backup saved: $DEST/dump.rdb"
