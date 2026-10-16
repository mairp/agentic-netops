#!/usr/bin/env bash
# Unit tests for the sonic-vm disk floor in scripts/lib/preflight.sh
# (feature 004, task T177: require 40 GB free disk on the sonic-vm profile).
# `df` is stubbed, so the result does not depend on this host's free space.
#   bash tests/unit/preflight_disk_floor_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/scripts/lib/preflight.sh"

PASS=0
FAIL=0

# check <name> <expected-rc> <expected-substring> <profile> <free-mb> <fn> [intent-tier]
check() {
    local name="$1" expect_rc="$2" expect_text="$3" profile="$4" free_mb="$5" fn="$6" tier="${7:-false}"
    local out rc
    out="$(
        unset AGENTIC_NETOPS_MIN_DISK_MB
        export AGENTIC_NETOPS_PROFILE="$profile" AGENTIC_NETOPS_WITH_INTENT_TIER="$tier"
        export AGENTIC_NETOPS_MIN_CPU=1 AGENTIC_NETOPS_MIN_MEM_MB=1
        # shellcheck source=scripts/lib/preflight.sh
        source "$PREFLIGHT"
        df() { printf 'Filesystem 1048576-blocks Used Available Capacity Mounted\nstub 1 1 %s 1%% /\n' "$free_mb"; }
        "$fn" 2>&1
    )"
    rc=$?
    if [[ "$rc" == "$expect_rc" && "$out" == *"$expect_text"* ]]; then
        echo "PASS $name (rc=$rc, saw: $expect_text)"
        PASS=$((PASS + 1))
    else
        echo "FAIL $name (rc=$rc want $expect_rc; want text: $expect_text)"
        echo "$out" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    fi
}

check "sonic-vm refuses 40959 MB free"  1 "Disk 40959MB free < required 40960MB" sonic-vm 40959 preflight::host_resources
check "sonic-vm accepts 40960 MB free"  0 "Disk free 40960>=40960 MB"           sonic-vm 40960 preflight::host_resources
check "sonic-vs keeps the 20 GB floor"  0 "Disk free 30000>=20480 MB"           sonic-vs 30000 preflight::host_resources
check "sonic-vm intent tier adds PVCs on the 40 GB floor" 0 "Disk free>=47104 MB" sonic-vm 50000 preflight::intent_tier_headroom true
check "sonic-vm intent tier refuses 47103 MB free" 1 "Disk 47103MB free < required 47104MB" sonic-vm 47103 preflight::intent_tier_headroom true
check "sonic-vs intent tier unchanged"  0 "Disk free>=26624 MB"                 sonic-vs 30000 preflight::intent_tier_headroom true

echo "preflight disk floor: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
