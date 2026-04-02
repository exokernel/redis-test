#!/usr/bin/env bash
# Show current cluster topology: pod status, which pod is master,
# replication info, and Redis version per pod.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# ── Pod overview ──────────────────────────────────────────────────────────────
# "kubectl get pods" is the k8s equivalent of "docker ps".
# READY column shows "running containers / total containers" per pod.
# With sentinel enabled each pod has 2 containers, so healthy = 2/2.

header "Pods  (namespace: $NAMESPACE)"
echo ""
kubectl get pods -n "$NAMESPACE" -l "$NODE_SELECTOR" \
    -o wide 2>/dev/null || echo "  (no pods found — is the cluster up?)"

# ── Sentinel state ────────────────────────────────────────────────────────────
# Sentinel is a sidecar in every pod, so we exec into whichever pod happens
# to be [0].  All sentinels share the same view of the cluster.

header "Sentinel State"
echo ""
sentinel_cli sentinel masters 2>/dev/null || echo "  (sentinel unavailable)"

# ── Master replication info ───────────────────────────────────────────────────

header "Master Replication Info"
echo ""

MASTER_POD=$(get_master_pod 2>/dev/null || true)
if [ -z "$MASTER_POD" ]; then
    echo "  Could not determine current master from sentinel."
else
    echo "  [Current master pod: $MASTER_POD]"
    echo ""
    kubectl exec -n "$NAMESPACE" "$MASTER_POD" -c redis -- \
        redis-cli info replication 2>/dev/null || echo "  (unavailable)"
fi

# ── Per-pod summary ───────────────────────────────────────────────────────────
# We exec into each pod individually to get its role and version.
# "kubectl exec" goes through the API server and kubelet — no direct network
# access to the pod required from your laptop.

header "All Redis Pods"
echo ""
printf "  %-20s %-10s %-10s %s\n" "Pod" "Role" "Version" "Image tag"
printf "  %-20s %-10s %-10s %s\n" "──────────────────" "────────" "───────" "─────────"

for pod in $(all_pods); do
    info=$(kubectl exec -n "$NAMESPACE" "$pod" -c redis -- \
        redis-cli info 2>/dev/null) || { printf "  %-20s %s\n" "$pod" "(offline)"; continue; }
    role=$(echo    "$info" | grep "^role:"          | tr -d '\r' | cut -d: -f2)
    version=$(echo "$info" | grep "^redis_version:" | tr -d '\r' | cut -d: -f2)
    image=$(kubectl get pod -n "$NAMESPACE" "$pod" \
        -o jsonpath='{.spec.containers[?(@.name=="redis")].image}' 2>/dev/null)
    printf "  %-20s %-10s %-10s %s\n" "$pod" "$role" "$version" "$image"
done
echo ""
