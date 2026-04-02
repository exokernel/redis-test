#!/usr/bin/env bash
# Verify test keys against the count saved by insert-data.sh.
# Checks total key count via SCAN and spot-checks every 10th key's value.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

KEYCOUNT_FILE="$SCRIPT_DIR/../.keycount"

if [ ! -f "$KEYCOUNT_FILE" ]; then
    echo "ERROR: .keycount not found. Run 'make k8s-insert' first."
    exit 1
fi

EXPECTED=$(cat "$KEYCOUNT_FILE")
PAD_WIDTH=${#EXPECTED}
FAIL=0

MASTER_POD=$(get_master_pod)
echo "Verifying data against master pod ($MASTER_POD)  [expected $EXPECTED keys]"
echo ""

# ── Count check ───────────────────────────────────────────────────────────────
ACTUAL=$(master_cli --scan --pattern "testkey:*" | wc -l | tr -d ' ')

if [ "$ACTUAL" -eq "$EXPECTED" ]; then
    echo "[PASS] Key count: $ACTUAL / $EXPECTED"
else
    echo "[FAIL] Key count: $ACTUAL / $EXPECTED"
    FAIL=1
fi

# ── Spot-check every 10th key ─────────────────────────────────────────────────
echo ""
echo "Spot-checking every 10th key..."

for i in $(seq 1 10 "$EXPECTED"); do
    key=$(printf "testkey:%0${PAD_WIDTH}d" "$i")
    expected_val="val-$(printf "%0${PAD_WIDTH}d" "$i")"
    actual_val=$(master_cli GET "$key" 2>/dev/null | tr -d '\r')
    if [ "$actual_val" = "$expected_val" ]; then
        echo "  [PASS] $key = $actual_val"
    else
        echo "  [FAIL] $key: expected '$expected_val'  got '$actual_val'"
        FAIL=1
    fi
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "All checks passed. No data loss detected."
else
    echo "VERIFICATION FAILED — data loss or corruption detected."
    exit 1
fi
