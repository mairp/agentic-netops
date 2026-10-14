#!/usr/bin/env bash
# vrf-apply.sh [node] — spike-vrf-apply-leaf01 / spike-vpn-state-<leaf> proof
# bodies (T074-T075). Creates the customer VRF through the GCU write path and
# attaches the node's srv6-client access port (Ethernet12, per the verified
# port map eth4):
#   1. /VRF = {Vrf1: {}} (whole-table add, falling back to the field-level
#      add of /VRF/Vrf1) — vrfmgrd creates the kernel VRF device and routing
#      table,
#   2. FIELD-LEVEL adds of Ethernet12 (vrf_name: Vrf1, a leafref into /VRF)
#      and its access prefix — never a whole-table /INTERFACE re-add: a
#      whole-table add REPLACES the table, and a failed add after a successful
#      removal leaves the fabric links WITHOUT interface config (measured on
#      leaf01: sessions dropped until the rows were re-added field-level).
#      Link addresses carry explicit masks (/31 v4, /127 v6) — the canonical
#      CONFIG_DB row format; bare addresses fail schema loading with
#      "Data Loading Failed",
#   3. read-backs: CONFIG_DB VRF/INTERFACE rows, kernel Vrf1 device and its
#      table id, Ethernet12 enslaved to Vrf1 with the address,
#   4. the srv6-client container gets 192.168.<svc>.2/24 + default route via
#      the leaf, and the proof pings the access gateway FROM the client
#      (in-VRF reachability, kernel-only: no SRv6 involvement yet).
# Idempotent by the same whole-table semantics as underlay-apply.sh; the
# client addressing is set-then-read-back.
set -u
. "$(dirname "$0")/spike-env.sh"
# Replay support (T105-T109): on a freshly provisioned lab this silently
# brings the underlay + locators up (fast path: probe all four nodes, only
# rebuild when a node is not converged). Prints nothing on the fast path.
. "$(dirname "$0")/ensure-fabric.sh"
ensure_fabric

n=${1:-leaf01}
c=$(container_of "$n")
case "$n" in
  leaf01) cl=$C_srv6_client01; svc=1 ;;
  leaf02) cl=$C_srv6_client02; svc=2 ;;
  *) echo "node must be leaf01|leaf02" >&2; exit 2 ;;
esac
# Fabric link addresses are only echoed for the record now; the apply itself
# no longer touches Ethernet0/Ethernet4 (field-level adds cannot disturb them).
fabric_field "$n" 5 >/dev/null 2>&1 || true

cat > /tmp/.spike_vrf.py <<'PY'
import sys
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
g = GenericUpdater()
# Idempotent re-run: silent whole-table removals in this process would wedge
# the instance if a table is absent, so removals run in their own process
# (see spike-locator-leaf01) and this one only adds.
# One chunk per table: GCU aborts a whole patch on the first failing op, so
# a VRF add failure must not stop the interface adds (and vice versa).
try:
    g.apply_patch(JsonPatch([{"op": "add", "path": "/VRF", "value": {"Vrf1": {}}}]),
                  ConfigFormat.CONFIGDB, False, False, False, [])
except Exception:
    try:  # /VRF already exists (idempotent re-run): add just the Vrf1 row
        g.apply_patch(JsonPatch([{"op": "add", "path": "/VRF/Vrf1", "value": {}}]),
                      ConfigFormat.CONFIGDB, False, False, False, [])
    except Exception:
        pass
# Field-level interface adds only — see header. Masks are explicit (/31 v4,
# /127 v6) matching the underlay's canonical rows.
# The address key contains "/" — JSON-pointer escape it (~1), else GCU
# cannot even address the row (leaf02: raw pointer fails both add+replace,
# escaped pointer works).
# FORCE-RESYNC: a re-add of a row whose value never changed is a no-op for
# intfmgrd, so kernel/CONFIG_DB drift is never repaired by the add loop
# (measured on leaf02: address row present in CONFIG_DB, kernel address gone
# after another writer's churn, 100% client loss, "add" then "replace" both
# silent no-ops). Removing the two access rows first forces intfmgrd to
# withdraw whatever it programmed and re-program from the adds below; absent
# rows remove silently.
access_key = "Ethernet12|192.168." + sys.argv[1] + ".1/24"
for path in ("/INTERFACE/" + access_key.replace("/", "~1"), "/INTERFACE/Ethernet12"):
    try:
        g.apply_patch(JsonPatch([{"op": "remove", "path": path}]),
                      ConfigFormat.CONFIGDB, False, False, False, [])
    except Exception:
        pass
for path, val in [
    ("/INTERFACE/Ethernet12", {"vrf_name": "Vrf1"}),
    ("/INTERFACE/" + access_key.replace("/", "~1"), {}),
]:
    for op in ("add", "replace"):  # add creates; replace updates in place
        try:
            g.apply_patch(JsonPatch([{"op": op, "path": path, "value": val}]),
                          ConfigFormat.CONFIGDB, False, False, False, [])
        except Exception:
            pass
print("APPLIED")
PY
cat > /tmp/.spike_vrf_rm.py <<'PY'
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
for path in ("/INTERFACE", "/VRF"):
    try:
        GenericUpdater().apply_patch(JsonPatch([{"op": "remove", "path": path}]), ConfigFormat.CONFIGDB, False, False, False, [])
    except Exception:
        pass
PY
push_file "$c" /tmp/.spike_vrf.py /tmp/.spike_vrf.py || true
# NOTE: there is deliberately NO whole-table removal step. The earlier design
# removed /INTERFACE whole-table before re-adding; a successful remove
# followed by a failed add wiped the fabric links' interface config (measured
# twice on leaf01: addresses left the kernel, iBGP went Active). Field-level
# force-resync removes + adds (above) touch only the two access rows.
# vrfmgrd/intfmgrd program the kernel asynchronously after the GCU write;
# right after a rollback+re-apply the access address lags seconds behind
# CONFIG_DB (measured: the read-back then shows Ethernet12 without its
# address and the client ping 100% loss, so a replay could not reproduce the
# stored .out). Silent bounded wait — prints nothing once the kernel state
# has arrived, so fast-path output stays byte-identical (FR-039).
vrf_k_ok() {
    local i kstate
    for i in $(seq 1 30); do
        kstate=$(node_run "$c" "ip link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\\.168\\.${svc}\\.1/' && echo K-OK" 2>/dev/null || true)
        [[ "$kstate" == *K-OK* ]] && return 0
        sleep 2
    done
    return 1
}
# A wedged orchagent (CONFIG_DB rows present, APPL_DB update never consumed,
# kernel never programmed — measured on leaf02, 2026-10-13 04:1x) once let
# this proof RECORD a half-programmed VRF with exit 0 and poison every
# downstream receipt. Each attempt runs its own GCU process (a failed patch
# wedges the instance, see the python header); three silent retries before
# failing loudly. Success output stays exactly one "APPLIED" line.
# PROBE-FIRST (pass 20): the force-resync remove+re-add of UNCHANGED rows is
# itself the orchagent wedge trigger (measured 2026-10-13: replay-time
# force-resync of a converged node left APPL_DB unconsumed -> APPLY-STUCK on
# that proof, cascading through the rest of its replay group). A node whose
# kernel state AND CONFIG_DB rows are already correct skips the writes
# entirely; only a non-converged node pays the remove+add dance. Output is
# the single "APPLIED" line either way, so recorded bytes do not change.
vrf_probe() {
    node_run "$c" "ip link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\\.168\\.${svc}\\.1/' && sudo redis-cli -n 4 --scan --pattern 'VRF|Vrf1' | grep -qx 'VRF|Vrf1' && sudo redis-cli -n 4 HGET 'INTERFACE|Ethernet12' vrf_name | grep -qx Vrf1 && echo P-OK" 2>/dev/null || true
}
# WEDGE CURE (2026-10-13, keeper-measured, refined after the 6th wedge): the
# orchagent write-blackout signature is CONFIG_DB rows present while APPL_DB
# never gets a VRF_TABLE entry and the kernel is never programmed. Cure is an
# in-guest systemd RESTART of swss (then syncd/bgp separately — restarting all
# three together fails on dependency ordering), NOT `start`: start is a no-op
# on active-but-wedged units, and NOT `docker restart swss`: the SIGKILL exit
# trips the unit's start-limit and leaves swss.service failed until
# reset-failed. The restart re-programs EVERYTHING from CONFIG_DB (the
# database container preserves it), so in the wedged state the GCU dance is
# skipped entirely — a remove+add dance on present-but-unprogrammed rows is
# itself the measured re-wedge trigger ("SET published then DEL'd"). The
# dance still runs for the rows-missing/fresh-apply state, where it is safe.
# Silent on success; output stays byte-identical either way.
vrf_wedged() {
    node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'VRF|Vrf1' | grep -qx 'VRF|Vrf1' && ! sudo redis-cli -n 0 --scan --pattern 'VRF_TABLE*' | grep -q . && echo W-OK" 2>/dev/null || true
}
vrf_wedge_cure() {
    # bgp is stopped only for the swss restart (bgpd must not talk into a
    # half-up swss); it comes back through bgp_unit_restart below — systemd
    # start with reset-failed first, Established wait and the 2-per-20-min
    # budget. The old inline `systemctl start bgp` here was the second of the
    # two restart sources that compounded into leaf01's StartLimitBurst trip
    # (measured 2026-10-13 21:03; `docker restart bgp` was the first).
    node_run "$c" "sudo systemctl stop bgp 2>/dev/null; sudo systemctl reset-failed swss syncd 2>/dev/null; sudo systemctl restart swss 2>/dev/null; sleep 5; sudo systemctl start syncd 2>/dev/null" >/dev/null 2>&1 || true
    local i s
    for i in $(seq 1 75); do
        s=$(node_run "$c" "systemctl is-active swss >/dev/null && sudo redis-cli -n 0 --scan --pattern 'VRF_TABLE*' | grep -q . && echo S-OK" 2>/dev/null || true)
        [[ "$s" == *S-OK* ]] && break
        sleep 2
    done
    bgp_unit_restart "$n" || true
    node_run "$c" "systemctl is-active swss >/dev/null && systemctl is-active bgp >/dev/null && sudo redis-cli -n 0 --scan --pattern 'VRF_TABLE*' | grep -q . && echo S-OK" 2>/dev/null | grep -q S-OK
}
if [[ "$(vrf_probe)" != *P-OK* ]]; then
if [[ "$(vrf_wedged)" == *W-OK* ]]; then
    vrf_wedge_cure
    applied=""
    vrf_k_ok || { echo "APPLY-STUCK: kernel VRF state did not converge after wedge cure" >&2; exit 1; }
else
applied=""
for _try in 1 2 3; do
    applied=$(node_run "$c" "sudo python3 /tmp/.spike_vrf.py \"$svc\"" 2>/dev/null | grep -E '^(APPLIED|ADD-FAILED)' || true)
    [[ "$applied" == "APPLIED" ]] && vrf_k_ok && break
    [[ "$_try" == 3 ]] && { echo "APPLY-STUCK: kernel VRF state did not converge after 3 attempts (applied='${applied:-none}')" >&2; exit 1; }
    sleep 5
done
fi
fi
echo "APPLIED"

echo "--- CONFIG_DB read-back ---"
node_run "$c" "sudo redis-cli -n 4 HGET 'VRF|Vrf1' NULL" || true
node_run "$c" "sudo redis-cli -n 4 HGET 'INTERFACE|Ethernet12' vrf_name" || true
node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'INTERFACE|Ethernet12*'" || true

echo "--- kernel VRF device and membership ---"
node_run "$c" "ip -br link show Vrf1 | sed 's/[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]/MAC/'" || true
# addr_norm masks the port's MAC-derived link-local; see spike-env.sh.
node_run "$c" "ip -br addr show Ethernet12" | addr_norm || true
node_run "$c" "ip route show table all | grep -c 192.168.${svc}.1" || true

echo "--- client attachment and in-VRF reachability ---"
# The client container's access port is eth1 (its IPv6 neighbor on eth1 is the
# leaf's Ethernet12 MAC); eth0 is the other veth and must be cleared of any
# stale trial addressing first.
client_run "$cl" "ip addr flush dev eth0" >/dev/null 2>&1 || true
client_run "$cl" "ip addr flush dev eth1" >/dev/null 2>&1 || true
client_run "$cl" "ip addr add 192.168.${svc}.2/24 dev eth1" || true
client_run "$cl" "ip route replace default via 192.168.${svc}.1 dev eth1" || true
# Silent warm-up ping: the first packet after addressing pays the ARP cost
# and can drop inside the recorded -c2 window (racy replay). Steady state is
# what this proof asserts; the warm-up prints nothing.
client_run "$cl" "ping -c1 -W2 192.168.${svc}.1 >/dev/null 2>&1" >/dev/null 2>&1 || true
client_run "$cl" "ping -c2 -W2 192.168.${svc}.1 2>&1 | tail -2" | ping_norm || true
