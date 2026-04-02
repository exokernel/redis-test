#!/usr/bin/env bash
# Insert COUNT test keys into the current sentinel-elected master.
# Keys: testkey:NNN  Values: val-NNN  (deterministic, verifiable)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

COUNT="${1:-100}"
KEYCOUNT_FILE="$SCRIPT_DIR/../.keycount"

MASTER_POD=$(get_master_pod)
PAD_WIDTH=${#COUNT}

echo "Inserting $COUNT test keys into master pod ($MASTER_POD)..."

# Pipe a batch of SET commands through redis-cli --pipe.
#
# In Compose this ran as:  redis-cli -p <host-port> --pipe
# In k8s it runs as:       kubectl exec -i ... -- redis-cli --pipe
#
# The -i flag passes our local stdin into the container.  The data never
# touches a host port — it goes:  shell → kubectl → API server → kubelet →
# container stdin.  Same result, different transport.
{
    for i in $(seq 1 "$COUNT"); do
        key=$(printf "testkey:%0${PAD_WIDTH}d" "$i")
        echo "SET $key val-$(printf "%0${PAD_WIDTH}d" "$i")"
    done
} | master_cli_pipe --pipe

# Verify using SCAN (never KEYS — same production discipline as compose)
ACTUAL=$(master_cli --scan --pattern "testkey:*" | wc -l | tr -d ' ')
echo "Inserted: $COUNT   Found via SCAN: $ACTUAL"

if [ "$ACTUAL" -ne "$COUNT" ]; then
    echo "ERROR: count mismatch after insert."
    exit 1
fi

echo "$COUNT" > "$KEYCOUNT_FILE"
echo "Key count saved to .keycount"
