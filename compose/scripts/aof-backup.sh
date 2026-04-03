#!/usr/bin/env bash
# Copy the live AOF file from the current master to ./backups/<timestamp>/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

BACKUP_BASE="$SCRIPT_DIR/../backups"
MASTER_NAME=$(get_current_master_name)

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEST="$BACKUP_BASE/$TIMESTAMP"
mkdir -p "$DEST"

echo "Copying AOF from $MASTER_NAME..."
docker cp "${MASTER_NAME}:/data/appendonly.aof" "$DEST/appendonly.aof"
echo "Backup saved: $DEST/appendonly.aof"
echo "$DEST" > "$SCRIPT_DIR/../.last_backup"
