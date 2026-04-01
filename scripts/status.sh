#!/usr/bin/env bash
# Show current cluster topology: sentinel state, master replication info,
# and a quick summary of all Redis nodes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

header "Sentinel State"

for port in 26379 26380; do
    name="sentinel-$((port - 26378))"
    echo ""
    echo "[$name (localhost:$port)]"
    redis-cli -p "$port" sentinel masters 2>/dev/null || echo "  (unavailable)"
done

header "Master Replication Info"

MASTER_NAME=$(get_current_master_name 2>/dev/null || true)
if [ -z "$MASTER_NAME" ]; then
    echo "  Could not determine current master from sentinel."
else
    MASTER_PORT=$(container_to_host_port "$MASTER_NAME")
    echo ""
    echo "[Current master: $MASTER_NAME (localhost:$MASTER_PORT)]"
    redis-cli -p "$MASTER_PORT" info replication 2>/dev/null || echo "  (unavailable)"
fi

header "All Redis Nodes"

echo ""
printf "  %-30s %-10s %-10s %s\n" "Node" "Port" "Role" "Version"
printf "  %-30s %-10s %-10s %s\n" "────────────────────────────" "────────" "────────" "───────"

declare -A PORT_MAP=(
    [redis-master]=6379
    [redis-replica-1]=6380
    [redis-replica-2]=6381
    [redis-replica-3]=6382
)

for name in redis-master redis-replica-1 redis-replica-2 redis-replica-3; do
    port="${PORT_MAP[$name]}"
    info=$(redis-cli -p "$port" info 2>/dev/null) || { printf "  %-30s %-10s %-10s %s\n" "$name" "$port" "offline" ""; continue; }
    role=$(echo "$info" | grep "^role:" | tr -d '\r' | cut -d: -f2)
    version=$(echo "$info" | grep "^redis_version:" | tr -d '\r' | cut -d: -f2)
    lag=$(echo "$info" | grep "^master_last_io_seconds_ago:" | tr -d '\r' | cut -d: -f2 || true)
    extra=""
    [ -n "$lag" ] && extra="lag=${lag}s"
    printf "  %-30s %-10s %-10s %-10s %s\n" "$name" "$port" "$role" "$version" "$extra"
done
echo ""
