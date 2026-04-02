#!/usr/bin/env bash
# Shared helpers for k8s scripts — sourced by all k8s scripts, not run directly.
#
# Kubernetes concepts used here:
#
#   Namespace    — logical isolation boundary inside a cluster. All our
#                  objects live in "redis-test".
#
#   StatefulSet  — like a Deployment but pods get stable names (redis-node-0,
#                  redis-node-1) and stable storage. Used for stateful workloads
#                  like Redis because pod identity matters for replication.
#
#   kubectl exec — equivalent to "docker exec". Runs a command inside a running
#                  container. Requires pod name + container name (-c) because
#                  each pod has two containers: "redis" and "sentinel".
#
#   Pod IP       — each pod gets its own IP inside the cluster. Sentinel stores
#                  the master's IP; we resolve it back to a pod name below.

RELEASE="redis"
NAMESPACE="redis-test"

# Label selector applied to all Redis node pods (set in manifests/statefulset.yaml)
NODE_SELECTOR="app.kubernetes.io/name=redis,app.kubernetes.io/component=node,app.kubernetes.io/instance=${RELEASE}"

header() {
    echo ""
    echo "────────────────────────────────────────────────"
    echo "  $*"
    echo "────────────────────────────────────────────────"
}

# Return a space-separated list of all running redis-node pod names.
all_pods() {
    kubectl get pods -n "$NAMESPACE" \
        -l "$NODE_SELECTOR" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null
}

# Run redis-cli on the sentinel sidecar of any pod (sentinel state is
# replicated across all pods, so any one will do).
sentinel_cli() {
    local pod
    pod=$(kubectl get pods -n "$NAMESPACE" -l "$NODE_SELECTOR" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$pod" ]; then
        echo "ERROR: no running Redis pods found in namespace $NAMESPACE" >&2
        exit 1
    fi
    # -c sentinel  →  target the sentinel container, not the redis container
    kubectl exec -n "$NAMESPACE" "$pod" -c sentinel -- redis-cli -p 26379 "$@"
}

# Find which pod is currently the Sentinel-elected master.
#
# How it works:
#   1. Ask any sentinel for the master's IP address.
#   2. List all pods and their IPs, find the one whose podIP matches.
#
# This is necessary because after a failover, any pod can be the master —
# there is no fixed "master pod", unlike in the Compose setup where
# redis-master is always the master until you explicitly promote a replica.
get_master_pod() {
    local master_addr
    master_addr=$(sentinel_cli sentinel get-master-addr-by-name mymaster 2>/dev/null | head -1)
    if [ -z "$master_addr" ]; then
        echo "ERROR: could not determine master from sentinel" >&2
        exit 1
    fi

    # Sentinel may return a pod IP or a DNS hostname.
    # Hostname format: redis-node-0.redis-headless.redis-test.svc.cluster.local
    # Distinguish by leading character: IPs start with a digit, hostnames with a letter.
    if echo "$master_addr" | grep -qE '^[0-9]'; then
        # It's an IP — map to pod name via kubectl
        kubectl get pods -n "$NAMESPACE" -l "$NODE_SELECTOR" \
            -o jsonpath="{range .items[*]}{.metadata.name}{'\t'}{.status.podIP}{'\n'}{end}" \
            | awk -v ip="$master_addr" '$2 == ip { print $1 }'
    else
        # It's a hostname — the pod name is the first DNS component
        echo "$master_addr" | cut -d. -f1
    fi
}

# Run redis-cli against the current master pod.
# Usage:  master_cli INFO replication
#         master_cli SET foo bar
master_cli() {
    local pod
    pod=$(get_master_pod)
    # -c redis  →  target the redis-server container (not the sentinel sidecar)
    kubectl exec -n "$NAMESPACE" "$pod" -c redis -- redis-cli "$@"
}

# Run redis-cli against the current master with stdin forwarded.
# Used for --pipe mode (bulk inserts).  The -i flag wires up local stdin
# to the container's stdin through the API server — same concept as
# "docker exec -i".
master_cli_pipe() {
    local pod
    pod=$(get_master_pod)
    kubectl exec -i -n "$NAMESPACE" "$pod" -c redis -- redis-cli "$@"
}
