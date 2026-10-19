#!/usr/bin/env bash
# locator-leaf01.sh — spike-locator-leaf01 proof body (T069-T073).
# Exercises the three locator write classes from docs/SRV6_SERVICE_RECIPE.md
# §1 on leaf01, in order, and proves underlay reachability of the node locator
# (fcbb:bbbb:3::/64, spike-env.sh locator_of). The run is deliberately
# re-entrant: every section starts from a state the script itself established
# (two bgp container restarts bracket the file experiment), so the proof
# replays byte-identically on this lab and on the T104 fresh redeploy.
#
#   S1  FRR file write class: locator block in /etc/sonic/frr/zebra.conf
#       (the same file the container sees at /etc/frr/zebra.conf — verified
#       by matching greps) is WIPED BY BGPCFGD at the next bgp container
#       start: after restart the file is back to the render and the FRR
#       locator table is empty. File restored from backup at section end.
#   S2  clean-file check: no locator block left (S3's empty-table baseline).
#   S3  GCU write class: SRV6_MY_LOCATORS row (prefix field is an ipv6-
#       ADDRESS on 202505 — sonic-yang-models rejects "fcbb:bbbb:3::/64" with
#       "does not satisfy the constraint"; the row stores fcbb:bbbb:3::)
#       lands in CONFIG_DB and THE FRR LOCATOR TABLE LISTS IT UP, derived as
#       fcbb:bbbb:3::/48 (block 32 + node 16) — CONFIG_DB is the supported
#       locator path; the interim refusal's empty table was the YANG address
#       rejection, not a missing manager. GCU idempotency measured: removing
#       the last row leaves an empty table, so a whole-table add after a
#       row-level remove raises; the trial removes the whole table first.
#   S4  durability: a bgp container restart re-programs the locator from
#       CONFIG_DB (srv6mgr at boot) — unlike the S1 file class, the row
#       survives restarts.
#   S5  underlay reachability: fcbb:bbbb:3::1/128 bound on Loopback0, zebra
#       static route for the /64, bgpd network statement — spine01 then holds
#       a BGP route for the /64 and pings the test address.
#   S6  cleanup: GCU table removed, kernel test address removed (vtysh state
#       is live-only by construction; the zebra.conf file is already clean).
set -u
. "$(dirname "$0")/spike-env.sh"

n=leaf01
c=$(container_of "$n")
loc=$(locator_of "$n")          # fcbb:bbbb:3::/64
testaddr=fcbb:bbbb:3::1

echo "===== S1. FRR file write class: wiped by bgpcfgd at container start ====="
# Backup hygiene: strip any prior trial block before taking the one-time
# backup, so the restore always returns the clean render (no-op on a fresh
# lab, self-healing on a reused one).
node_run "$c" "sudo sed -i '/^segment-routing$/,/^  !$/d' /etc/sonic/frr/zebra.conf" || true
node_run "$c" "sudo test -f /tmp/.spike_zebra_bak || sudo cp /etc/sonic/frr/zebra.conf /tmp/.spike_zebra_bak" || true
node_run "$c" "sudo cp /tmp/.spike_zebra_bak /etc/sonic/frr/zebra.conf" || true
node_run "$c" "printf '\nsegment-routing\n srv6\n  locators\n   locator LOC1\n    prefix $loc block-len 32 node-len 32 func-bits 16\n   exit\n   !\n  exit\n  !\n' | sudo tee -a /etc/sonic/frr/zebra.conf >/dev/null" || true
echo "--- block present before restart (host view | container view) ---"
node_run "$c" "sudo grep -c 'locator LOC1' /etc/sonic/frr/zebra.conf; sudo docker exec bgp grep -c 'locator LOC1' /etc/frr/zebra.conf" || true
bgp_container_restart "$n" || true
echo "--- same two greps after restart ---"
node_run "$c" "sudo grep -c 'locator LOC1' /etc/sonic/frr/zebra.conf; sudo docker exec bgp grep -c 'locator LOC1' /etc/frr/zebra.conf" || true
node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" || true
node_run "$c" "sudo cp /tmp/.spike_zebra_bak /etc/sonic/frr/zebra.conf" || true

echo "===== S2. clean-file check (S3's empty-table baseline) ====="
node_run "$c" "sudo grep -c 'locator LOC1' /etc/sonic/frr/zebra.conf || true" || true

echo "===== S3. GCU write class: CONFIG_DB row reaches FRR (derived /48) ====="
# Idempotent re-run (measured GCU semantics): a remove onto an absent table
# wedges that python process's subsequent patches, and an add onto any
# existing table raises ValueError — so the removal runs first, silently, in
# its own process, and the add runs in a fresh one.
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
        {"loc-spike": {"prefix": sys.argv[1]}}}]
try:
    GenericUpdater().apply_patch(JsonPatch(ops), ConfigFormat.CONFIGDB, False, False, False, [])
    print("APPLIED")
except Exception as e:
    print("ADD-FAILED %s" % type(e).__name__)
PY
push_file "$c" /tmp/.spike_loc_rm.py /tmp/.spike_loc_rm.py || true
push_file "$c" /tmp/.spike_loc.py /tmp/.spike_loc.py || true
node_run "$c" "sudo python3 /tmp/.spike_loc_rm.py" >/dev/null 2>&1 || true
node_run "$c" "sudo python3 /tmp/.spike_loc.py ${loc%/*}" 2>/dev/null | grep -E '^(APPLIED|ADD-FAILED)' || echo "APPLY-FAILED"
node_run "$c" "sudo redis-cli -n 4 HGET 'SRV6_MY_LOCATORS|loc-spike' prefix" || true
node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" || true

echo "===== S4. durability: locator re-programmed from CONFIG_DB after restart ====="
bgp_container_restart "$n" || true
node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" || true

echo "===== S5. underlay reachability of $loc ====="
node_run "$c" "sudo ip -6 addr replace $testaddr/128 dev Loopback0" || true
node_run "$c" "vtysh -c 'conf t' -c \"ipv6 route $loc Loopback0\" -c 'end'" || true
node_run "$c" "vtysh -c 'conf t' -c 'router bgp $(fabric_field "$n" 2)' -c 'address-family ipv6 unicast' -c \"network $loc\" -c 'end'" || true
# S4's restart dropped leaf01's sessions; let them re-establish and the
# network statement propagate before reading state (harness-side, silent).
sleep 15
echo "--- leaf01 route for the locator ---"
node_run "$c" "vtysh -c 'show ipv6 route'" | grep "fcbb:bbbb:3" | bgp_norm || true
echo "--- spine01 BGP route for the locator ---"
node_run "$(container_of spine01)" "vtysh -c 'show ipv6 route'" | grep "fcbb:bbbb:3" | bgp_norm || true
echo "--- spine01 ping of $testaddr ---"
node_run "$(container_of spine01)" "ping -c2 -W2 -I 2001:db8:ff::11 $testaddr 2>&1 | tail -2" | ping_norm || true

echo "===== S6. cleanup: GCU table and kernel test address removed ====="
node_run "$c" "sudo python3 /tmp/.spike_loc_rm.py" >/dev/null 2>&1 || true
node_run "$c" "sudo redis-cli -n 4 HGET 'SRV6_MY_LOCATORS|loc-spike' prefix" || true
node_run "$c" "sudo ip -6 addr del $testaddr/128 dev Loopback0 2>/dev/null; true" || true
