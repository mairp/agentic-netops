#!/usr/bin/env bash
# locator-all.sh — spike-locator-all proof body (T069-T073, all nodes).
# Writes one SRV6_MY_LOCATORS row per node via GCU (the supported CONFIG_DB
# write class established by spike-locator-leaf01: the prefix field is an
# ipv6-ADDRESS; FRR lists the derived /48) and reads back redis + the FRR
# locator table on each of the four nodes. Idempotent by the measured GCU
# semantics: the removal runs silently in its own process (a failed patch
# wedges that process's subsequent patches), the add in a fresh one. No
# restarts here; restart durability is the leaf01 proof's S4 finding
# (re-assertion required after a bgp container restart).
set -u
. "$(dirname "$0")/spike-env.sh"

cat > /tmp/.spike_loc_rm.py <<'PY'
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
try:
    GenericUpdater().apply_patch(JsonPatch([{"op": "remove", "path": "/SRV6_MY_LOCATORS"}]), ConfigFormat.CONFIGDB, False, False, False, [])
except Exception:
    pass
PY
cat > /tmp/.spike_loc.py <<'PY'
import sys
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
ops = [{"op": "add", "path": "/SRV6_MY_LOCATORS", "value":
        {"loc-" + sys.argv[1].lower(): {"prefix": sys.argv[2]}}}]
try:
    GenericUpdater().apply_patch(JsonPatch(ops), ConfigFormat.CONFIGDB, False, False, False, [])
    print("APPLIED")
except Exception as e:
    print("ADD-FAILED %s" % type(e).__name__)
PY

for n in spine01 spine02 leaf01 leaf02; do
    c=$(container_of "$n")
    addr=$(locator_of "$n"); addr=${addr%/*}     # /64 -> YANG ipv6-address
    echo "===== $n: locator $addr/64 via GCU ====="
    push_file "$c" /tmp/.spike_loc_rm.py /tmp/.spike_loc_rm.py || true
    push_file "$c" /tmp/.spike_loc.py /tmp/.spike_loc.py || true
    node_run "$c" "sudo python3 /tmp/.spike_loc_rm.py" >/dev/null 2>&1 || true
    node_run "$c" "sudo python3 /tmp/.spike_loc.py \"$n\" \"$addr\"" 2>/dev/null | grep -E '^(APPLIED|ADD-FAILED)' || echo "APPLY-FAILED"
    node_run "$c" "sudo redis-cli -n 4 HGET 'SRV6_MY_LOCATORS|loc-${n}' prefix" || true
    node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" | grep -E "loc-${n}|Name|----|^$" || true
done
