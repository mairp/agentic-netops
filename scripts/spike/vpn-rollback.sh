#!/usr/bin/env bash
# vpn-rollback.sh — spike-vpn-rollback proof body (T081).
# Removes the ip-vrf/vpn service directly on both leaves and reads back that
# nothing owned by it remains and the node locator is untouched:
#   - the steering and decap routes (iproute2) first, so the VRF device is
#     empty when vrfmgrd deletes it,
#   - the CONFIG_DB VRF and the whole INTERFACE attachment set (GCU
#     whole-table remove in its own process, then a re-add of exactly the two
#     fabric links in a fresh process - the known-good idempotency pattern),
#   - the client addressing (flushed),
#   - the locator: SRV6_MY_LOCATORS row and the FRR locator table stay.
set -u
. "$(dirname "$0")/spike-env.sh"
c1=$(container_of leaf01); c2=$(container_of leaf02)

cat > /tmp/.spike_vpn_rb2.py <<'PY'
import sys
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
e0v4, e4v4, e0v6, e4v6 = sys.argv[1:5]
g = GenericUpdater()
# SPIKE_FABRIC carries bare addresses; CONFIG_DB rows are the canonical masked
# form (/31 v4, /127 v6) — bare addresses fail YANG schema loading ("Data
# Loading Failed", measured).
def msk(a):
    return a + ("/31" if ":" not in a else "/127")
ops = [{"op": "add", "path": "/INTERFACE", "value": {
    "Ethernet0": {}, "Ethernet0|" + msk(e0v4): {},
    "Ethernet4": {}, "Ethernet4|" + msk(e4v6): {},
    "Ethernet0|" + msk(e0v6): {}, "Ethernet4|" + msk(e4v4): {}}}]
# fabric rows only: no Vrf1, no access port
for op in ops:
    try:
        g.apply_patch(JsonPatch([op]), ConfigFormat.CONFIGDB, False, False, False, [])
        print("INTERFACE-RESTORED")
    except Exception as e:
        print("RESTORE-FAILED %s" % type(e).__name__)
PY
push_file "$c1" /tmp/.spike_vpn_rb2.py /tmp/.spike_vpn_rb2.py || true
push_file "$c2" /tmp/.spike_vpn_rb2.py /tmp/.spike_vpn_rb2.py || true

echo "===== remove service on both leaves ====="
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    e0v4=$(fabric_field "$n" 5 | tr ';' '\n' | head -1 | cut -d, -f2)
    e4v4=$(fabric_field "$n" 5 | tr ';' '\n' | sed -n 2p | cut -d, -f2)
    e0v6=$(fabric_field "$n" 5 | tr ';' '\n' | head -1 | cut -d, -f5)
    e4v6=$(fabric_field "$n" 5 | tr ';' '\n' | sed -n 2p | cut -d, -f5)
    echo "-- $n --"
    # 1. any leftover SRV6_MY_SIDS row first: its decap_vrf is a YANG leafref
    #    into /VRF, so /VRF below would be REJECTED while the row exists
    #    (measured: "REMOVE-SKIP /VRF ValueError"). Own process (wedge
    #    semantics). vpn-setup pushes /tmp/.spike_sids_rm.py; if it is not
    #    there, fall through — the table simply has no row to remove.
    for _i in 1 2 3; do
        node_run "$c" "sudo python3 /tmp/.spike_sids_rm.py" >/dev/null 2>&1 || true
        _left=$(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_SIDS*' | wc -l" 2>/dev/null || echo 0)
        [ "${_left:-0}" = "0" ] && break
        sleep 2
    done
    # 2. routes first (iproute2), decap prefixes repeated until gone: the
    #    as-built decap and a zebra static (proto 196) left by an interrupted
    #    sid-write run are separate kernel routes for the same prefix — one
    #    del removes exactly one.
    node_run "$c" "sudo ip route del vrf Vrf1 192.168.2.0/24 2>/dev/null; sudo ip route del vrf Vrf1 192.168.1.0/24 2>/dev/null; for i in 1 2 3 4 5; do sudo ip -6 route del fcbb:bbbb:3:11::/64 2>/dev/null || break; done; for i in 1 2 3 4 5; do sudo ip -6 route del fcbb:bbbb:4:11::/64 2>/dev/null || break; done; true"
    # 3. whole-table removes in their own processes (wedge semantics), then restore fabric rows
    node_run "$c" "sudo python3 -c \"
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
for p in ('/INTERFACE', '/VRF'):
    try:
        GenericUpdater().apply_patch(JsonPatch([{'op': 'remove', 'path': p}]), ConfigFormat.CONFIGDB, False, False, False, [])
        print('REMOVED', p)
    except Exception as e:
        print('REMOVE-SKIP', p, type(e).__name__)
\"" 2>/dev/null || true
    node_run "$c" "sudo python3 /tmp/.spike_vpn_rb2.py \"$e0v4\" \"$e4v4\" \"$e0v6\" \"$e4v6\"" 2>/dev/null | grep -E 'INTERFACE-RESTORED|RESTORE-FAILED' || true
done

echo "===== read back: nothing owned by the service remains ====="
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    echo "-- $n --"
    node_run "$c" "sudo redis-cli -n 4 keys 'VRF|Vrf*'" | grep -q . && echo "VRF-ROW-STILL-PRESENT" || echo "VRF rows: none"
    node_run "$c" "sudo redis-cli -n 4 keys 'INTERFACE|Ethernet12*'" | grep -q . && echo "ATTACH-STILL-PRESENT" || echo "attachment rows: none"
    node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_SIDS*'" | grep -q . && echo "SID-ROW-STILL-PRESENT" || echo "SID rows: none"
    node_run "$c" "ip -br link show Vrf1 2>/dev/null | grep -q . && echo 'VRF-DEVICE-STILL-PRESENT' || echo 'Vrf1 device: gone'"
    node_run "$c" "ip -6 route show | grep -c seg6local" | sed 's/^/seg6local routes: /' || true
    node_run "$c" "ip -br addr show Ethernet0 | grep -o '10.1.0.[0-9]*/31'" || true
done
echo "-- clients flushed --"
client_run "$C_srv6_client01" "ip addr flush dev eth1" >/dev/null 2>&1 || true
client_run "$C_srv6_client02" "ip addr flush dev eth1" >/dev/null 2>&1 || true
echo "client01 eth1: $(client_run "$C_srv6_client01" "ip -4 -br addr show eth1" 2>/dev/null)"
echo "client02 eth1: $(client_run "$C_srv6_client02" "ip -4 -br addr show eth1" 2>/dev/null)"

echo "===== locator untouched (bootstrap-owned) ====="
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    echo "-- $n --"
    node_run "$c" "sudo redis-cli -n 4 HGET 'SRV6_MY_LOCATORS|loc-${n}' prefix" || true
    node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" | grep "loc-${n}" || true
done
