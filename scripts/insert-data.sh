#!/usr/bin/env bash
# Insert COUNT test keys into the current master.
# Keys: testkey:NNN  Values: val-NNN  (deterministic, verifiable)
# Saves the count to .keycount for verify-data.sh to read.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

COUNT="${1:-100}"
KEYCOUNT_FILE="$SCRIPT_DIR/../.keycount"

MASTER_PORT=$(get_current_master_port)
PAD_WIDTH=${#COUNT}

echo "Inserting $COUNT test keys into master (localhost:$MASTER_PORT)..."

# Batch writes via pipeline for speed
{
    for i in $(seq 1 "$COUNT"); do
        key=$(printf "testkey:%0${PAD_WIDTH}d" "$i")
        echo "SET $key val-$(printf "%0${PAD_WIDTH}d" "$i")"
    done
} | redis-cli -p "$MASTER_PORT" --pipe

# Verify the count using SCAN (never uses KEYS)
ACTUAL=$(redis-cli -p "$MASTER_PORT" --scan --pattern "testkey:*" | wc -l | tr -d ' ')
echo "Inserted: $COUNT   Found via SCAN: $ACTUAL"

if [ "$ACTUAL" -ne "$COUNT" ]; then
    echo "ERROR: count mismatch after insert."
    exit 1
fi

echo "$COUNT" > "$KEYCOUNT_FILE"
echo "Key count saved to .keycount"
