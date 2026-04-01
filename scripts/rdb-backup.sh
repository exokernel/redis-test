#!/usr/bin/env bash
# Trigger BGSAVE on the current master, wait for it to complete,
# then copy dump.rdb to ./backups/<timestamp>/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

BACKUP_BASE="$SCRIPT_DIR/../backups"
MASTER_PORT=$(get_current_master_port)
MASTER_NAME=$(get_current_master_name)

echo "Triggering BGSAVE on $MASTER_NAME (localhost:$MASTER_PORT)..."

BEFORE=$(redis-cli -p "$MASTER_PORT" LASTSAVE)
redis-cli -p "$MASTER_PORT" BGSAVE > /dev/null

echo -n "Waiting for BGSAVE to complete"
while true; do
    AFTER=$(redis-cli -p "$MASTER_PORT" LASTSAVE)
    [ "$AFTER" != "$BEFORE" ] && break
    echo -n "."
    sleep 1
done
echo " done."

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEST="$BACKUP_BASE/$TIMESTAMP"
mkdir -p "$DEST"

docker cp "${MASTER_NAME}:/data/dump.rdb" "$DEST/dump.rdb"
echo "Backup saved: $DEST/dump.rdb"
echo "$DEST" > "$SCRIPT_DIR/../.last_backup"
