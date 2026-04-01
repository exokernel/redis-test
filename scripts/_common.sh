#!/usr/bin/env bash
# Shared helpers — sourced by all scripts. Not executed directly.

SENTINEL_HOST="localhost"
SENTINEL_PORT_1=26379
SENTINEL_PORT_2=26380
PROJECT_NAME="redis-test"

# Known containers and their host-exposed ports
declare -A HOST_PORT_MAP=(
    [redis-master]=6379
    [redis-replica-1]=6380
    [redis-replica-2]=6381
    [redis-replica-3]=6382
)

header() {
    echo ""
    echo "────────────────────────────────────────────────"
    echo "  $*"
    echo "────────────────────────────────────────────────"
}

confirm() {
    local msg="${1:-Continue?}"
    echo ""
    echo -n "$msg [y/N] "
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

# Map container name → host-exposed port
container_to_host_port() {
    local name="$1"
    # If it's already a known name, return directly
    if [[ -n "${HOST_PORT_MAP[$name]+x}" ]]; then
        echo "${HOST_PORT_MAP[$name]}"
        return
    fi
    # Might be a Docker-internal IP — resolve via docker inspect
    for cname in "${!HOST_PORT_MAP[@]}"; do
        local cip
        cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cname" 2>/dev/null) || continue
        if [ "$cip" = "$name" ]; then
            echo "${HOST_PORT_MAP[$cname]}"
            return
        fi
    done
    echo "ERROR: cannot map '$name' to a host port" >&2
    exit 1
}

# Resolve a container name or IP to the container name
resolve_container_name() {
    local addr="$1"
    # Check if it's already a known container name
    if [[ -n "${HOST_PORT_MAP[$addr]+x}" ]]; then
        echo "$addr"
        return
    fi
    # Resolve IP to container name
    for cname in "${!HOST_PORT_MAP[@]}"; do
        local cip
        cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cname" 2>/dev/null) || continue
        if [ "$cip" = "$addr" ]; then
            echo "$cname"
            return
        fi
    done
    echo "$addr"  # fallback: return as-is
}

# Query sentinel for current master address (may be IP or hostname)
get_current_master_addr() {
    redis-cli -h "$SENTINEL_HOST" -p "$SENTINEL_PORT_1" \
        sentinel get-master-addr-by-name mymaster 2>/dev/null | head -1
}

# Get the container name of the current master
get_current_master_name() {
    local addr
    addr=$(get_current_master_addr)
    resolve_container_name "$addr"
}

# Query sentinel and return the host-exposed port of the current master
get_current_master_port() {
    local addr
    addr=$(get_current_master_addr)
    if [ -z "$addr" ]; then
        echo "ERROR: could not query sentinel at $SENTINEL_HOST:$SENTINEL_PORT_1" >&2
        exit 1
    fi
    container_to_host_port "$addr"
}

# Run redis-cli against current master (passes through extra args)
master_cli() {
    local port
    port=$(get_current_master_port)
    redis-cli -p "$port" "$@"
}
