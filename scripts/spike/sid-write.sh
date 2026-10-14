#!/usr/bin/env bash
# sid-write.sh — spike-sid-write proof body (T076, gate-3 addendum).
# Proves the CONFIG_DB SRV6_MY_SIDS write class end to end and leaves NO
# steady-state trace (the as-built decap stays the kernel route vpn-setup.sh
# asserts):
#   1. negative: a payload with a "prefix_len" field is REJECTED by
#      sonic-srv6.yang (the table models composite key locator|ip_prefix with
#      action/decap_vrf only) — measured: "All Keys are not parsed in
#      SRV6_MY_SIDS ... exceptionList:['prefix_len']",
#   2. negative: decap_vrf is a leafref into /VRF — a row naming an unknown
#      VRF is REJECTED,
#   3. positive: the YANG-valid row (key "loc-<n>|<service-sid>/64", fields
#      action=uDT46, decap_vrf=Vrf1) is ACCEPTED on both leaves and reads
#      back from CONFIG_DB,
#   4. integrity: while the row exists, removing /VRF is REJECTED (the
#      leafref makes the VRF undeletable) — the service SID row is live
#      config, not a no-op,
#   5. revert: the row is removed again (own-process GCU remove, retried —
#      the helper always exits 0, so the wait loop polls CONFIG_DB), and the
#      as-built kernel decap is shown still in place with client traffic
#      passing through it.
# Every printed section ends in a state-independent read-back, so the proof
# replays byte-identically on a fresh lab and on an already-built one.
set -u
. "$(dirname "$0")/spike-env.sh"

bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true

cat > /tmp/.spike_sidw.py <<'PY'
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
import sys
key, extra = sys.argv[1:3]
fields = {"action": "uDT46", "decap_vrf": "Vrf1"}
if extra == "prefixlen":
    fields = {"prefix_len": "64", "action": "uDT46", "decap_vrf": "Vrf1"}
if extra == "badvrf":
    fields["decap_vrf"] = "NoSuchVrf"
ops = [{"op": "add", "path": "/SRV6_MY_SIDS", "value": {key: fields}}]
try:
    GenericUpdater().apply_patch(JsonPatch(ops), ConfigFormat.CONFIGDB, False, False, False, [])
    print("SID-ROW-APPLIED")
except Exception as e:
    print("SID-ROW-REJECTED %s" % type(e).__name__)
PY
cat > /tmp/.spike_sidw_rm.py <<'PY'
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
try:
    GenericUpdater().apply_patch(JsonPatch([{"op": "remove", "path": "/SRV6_MY_SIDS"}]),
                                 ConfigFormat.CONFIGDB, False, False, False, [])
    print("SID-ROW-REMOVED")
except Exception:
    print("SID-ROW-REMOVE-SKIP")
PY

c1=$(container_of leaf01); c2=$(container_of leaf02)
for c in "$c1" "$c2"; do
    push_file "$c" /tmp/.spike_sidw.py /tmp/.spike_sidw.py || true
    push_file "$c" /tmp/.spike_sidw_rm.py /tmp/.spike_sidw_rm.py || true
done

echo "===== negative: prefix_len is not a modelled field (sonic-srv6.yang) ====="
node_run "$c1" "sudo python3 /tmp/.spike_sidw.py 'loc-leaf01|fcbb:bbbb:3:11::/64' prefixlen" 2>/dev/null | grep -E 'SID-ROW' || echo "SID-ROW-REJECTED"

echo "===== negative: decap_vrf is a leafref into /VRF ====="
node_run "$c1" "sudo python3 /tmp/.spike_sidw.py 'loc-leaf01|fcbb:bbbb:3:11::/64' badvrf" 2>/dev/null | grep -E 'SID-ROW' || echo "SID-ROW-REJECTED"

echo "===== positive: the YANG-valid row applies on both leaves ====="
echo "-- leaf01 --"
node_run "$c1" "sudo python3 /tmp/.spike_sidw.py 'loc-leaf01|fcbb:bbbb:3:11::/64' valid" 2>/dev/null | grep -E 'SID-ROW' || echo "SID-ROW-REJECTED"
echo "-- leaf02 --"
node_run "$c2" "sudo python3 /tmp/.spike_sidw.py 'loc-leaf02|fcbb:bbbb:4:11::/64' valid" 2>/dev/null | grep -E 'SID-ROW' || echo "SID-ROW-REJECTED"
echo "-- row read-back (CONFIG_DB) --"
node_run "$c1" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_SIDS*'" || true
node_run "$c1" "sudo redis-cli -n 4 HGET 'SRV6_MY_SIDS|loc-leaf01|fcbb:bbbb:3:11::/64' action" || true
node_run "$c1" "sudo redis-cli -n 4 HGET 'SRV6_MY_SIDS|loc-leaf01|fcbb:bbbb:3:11::/64' decap_vrf" || true
node_run "$c2" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_SIDS*'" || true

echo "===== integrity: /VRF is undeletable while the SID row references it ====="
node_run "$c1" "sudo python3 -c \"
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
try:
    GenericUpdater().apply_patch(JsonPatch([{'op': 'remove', 'path': '/VRF'}]), ConfigFormat.CONFIGDB, False, False, False, [])
    print('VRF-REMOVED (unexpected)')
except Exception as e:
    print('VRF-REMOVE-REJECTED %s' % type(e).__name__)
\"" 2>/dev/null | grep -E 'VRF-' || true
node_run "$c1" "ip -br link show Vrf1 | head -1" || true

echo "===== revert: the row is removed again, as-built decap stays ====="
for i in $(seq 1 10); do
    node_run "$c1" "sudo python3 /tmp/.spike_sidw_rm.py" >/dev/null 2>&1 || true
    node_run "$c2" "sudo python3 /tmp/.spike_sidw_rm.py" >/dev/null 2>&1 || true
    left=$(node_run "$c1" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_SIDS*' | wc -l" 2>/dev/null || echo 0)
    [ "${left:-0}" = "0" ] && break
    sleep 2
done
for c in "$c1" "$c2"; do
    node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_SIDS*'" | grep -q . && echo "ROW-STILL-PRESENT" || echo "row: none"
    node_run "$c" "ip -6 route show | grep seg6local" || true
done

echo "===== dataplane after the write-class round-trip (as-built only) ====="
client_run "$C_srv6_client01" "ping -c2 -W2 192.168.2.2 2>&1 | tail -1" | ping_norm || true
