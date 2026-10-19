#!/usr/bin/env bash
# locator-node.sh <node> — spike-locator-<node> proof body (T069-T072).
# Writes the node locator with the class established on leaf01 (CONFIG_DB
# SRV6_MY_LOCATORS through the GCU) and reads it back from redis and from
# the FRR locator table. Idempotent: silent whole-table removal in its own
# process, then the add in a fresh one (measured GCU wedge semantics).
set -u
. "$(dirname "$0")/spike-env.sh"
n=${1:?node required}
c=$(container_of "$n")
addr=$(locator_of "$n"); addr=${addr%/*}

cat > /tmp/.spike_locn_rm.py <<'PY'
import sys
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
try:
    GenericUpdater().apply_patch(JsonPatch([{"op": "remove",
        "path": "/SRV6_MY_LOCATORS[loc-" + sys.argv[1] + "]", "value": {}}]),
        ConfigFormat.CONFIGDB, False, False, False, [])
except Exception:
    pass
PY
cat > /tmp/.spike_locn.py <<'PY'
import sys
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
node, addr = sys.argv[1:3]
ops = [{"op": "add", "path": "/SRV6_MY_LOCATORS", "value":
        {"loc-" + node.lower(): {"prefix": addr}}}]
try:
    GenericUpdater().apply_patch(JsonPatch(ops), ConfigFormat.CONFIGDB, False, False, False, [])
    print("APPLIED")
except Exception as e:
    print("ADD-FAILED %s" % type(e).__name__)
PY
push_file "$c" /tmp/.spike_locn_rm.py /tmp/.spike_locn_rm.py || true
push_file "$c" /tmp/.spike_locn.py /tmp/.spike_locn.py || true
node_run "$c" "sudo python3 /tmp/.spike_locn_rm.py \"$n\"" >/dev/null 2>&1 || true
echo "===== $n: locator $addr/64 via GCU (CONFIG_DB class) ====="
node_run "$c" "sudo python3 /tmp/.spike_locn.py \"$n\" \"$addr\"" 2>/dev/null | grep -E '^(APPLIED|ADD-FAILED)' || echo "APPLY-FAILED"
echo "--- redis read-back ---"
node_run "$c" "sudo redis-cli -n 4 HGET 'SRV6_MY_LOCATORS|loc-${n}' prefix" || true
echo "--- FRR locator table ---"
node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" | grep -E "loc-${n}|Name|---" || true
# T069 (attempt-3): the locator write classes, each measured on the device —
# whether the row is accepted AND whether FRR shows the locator — followed by
# ONE bgp unit restart as the persistence discriminator (vtysh/live state dies
# with the unit, the bgpd.conf render is regenerated from CONFIG_DB by bgpcfgd
# at start, CONFIG_DB rows re-render through frrcfgd). Only leaf01 runs this:
# it is the node the data-model service examples address. Locator shape note
# (measured below): FRR rejects block-len+node-len != prefix length, so the
# probes use the as-built /48 shape, plus one deliberately malformed /64 to
# record the rejection text.
if [[ "$n" == leaf01 ]]; then
    T01=loc-spike-t01   # redis-direct class probe (raw HSET, no YANG defaults)
    TV=loc-spike-v      # vtysh class probe (live FRR state)
    TF=loc-spike-f      # FRR-file class probe (append bgpd.conf in the bgp ctr)
    P01=fcbb:bbbb:3f::/48
    PV=fcbb:bbbb:3e::/48
    PF=fcbb:bbbb:3d::/48
    echo "===== $n: locator write classes (T069) ====="

    echo "--- class 1: redis-direct (raw HSET SRV6_MY_LOCATORS, bypasses YANG defaults) ---"
    node_run "$c" "sudo redis-cli -n 4 HSET 'SRV6_MY_LOCATORS|$T01' prefix $P01" </dev/null || true
    echo "row read-back: $(node_run "$c" "sudo redis-cli -n 4 --raw HGETALL 'SRV6_MY_LOCATORS|$T01'" </dev/null | paste - -)"
    sleep 4
    fr01=$(node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" | grep "$T01" | wc -l)
    echo "REDIS-DIRECT-CLASS row-accepted=yes frr-shows=$([ "${fr01:-0}" -gt 0 ] && echo yes || echo no) frr-row: $(node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" | grep "$T01")"

    echo "--- class 2: vtysh (live FRR configuration) ---"
    echo "attempt a) malformed /64 shape (block-len+node-len != 64) — expect rejection:"
    node_run "$c" "vtysh -c 'conf t' -c 'segment-routing' -c 'srv6' -c 'locators' -c 'locator $TV' -c 'prefix fcbb:bbbb:3e::/64 block-len 32 node-len 16 func-bits 16' -c 'end'" 2>&1 </dev/null | grep -E '%|Unknown|Error' || true
    echo "attempt b) as-built /48 shape:"
    node_run "$c" "vtysh -c 'conf t' -c 'segment-routing' -c 'srv6' -c 'locators' -c 'locator $TV' -c 'prefix $PV block-len 32 node-len 16 func-bits 16' -c 'behavior usid' -c 'end'" 2>&1 </dev/null || true
    sleep 2
    fv=$(node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" | grep "$TV" | wc -l)
    echo "VTYSH-CLASS row-accepted=$([ "${fv:-0}" -gt 0 ] && echo yes || echo no) frr-shows=$([ "${fv:-0}" -gt 0 ] && echo yes || echo no) persistence=live-only(known)"

    echo "--- class 3: FRR file (append /etc/frr/bgpd.conf in the bgp container) ---"
    cat > /tmp/.spike_locblock.txt <<FRRB
!
segment-routing
 srv6
  locators
   locator $TF
    prefix $PF block-len 32 node-len 16 func-bits 16
    behavior usid
   exit
  exit
 !
exit
!
FRRB
    push_file "$c" /tmp/.spike_locblock.txt /tmp/.spike_locblock.txt || true
    node_run "$c" "sudo sh -c 'cat /tmp/.spike_locblock.txt | docker exec -i bgp sh -c \"cat >> /etc/frr/bgpd.conf\"'" </dev/null || true
    echo "file content after append:"
    node_run "$c" "sudo docker exec bgp grep -A2 '$TF' /etc/frr/bgpd.conf" </dev/null || true
    ff=$(node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" | grep "$TF" | wc -l)
    echo "FRR-FILE-CLASS file-updated=yes frr-shows-without-restart=$([ "${ff:-0}" -gt 0 ] && echo yes || echo no)"

    echo "--- class 4: GCU (CONFIG_DB apply-patch) = the class the base section used ---"

    echo "===== $n: persistence discriminator (one bgp unit restart) ====="
    bgp_unit_restart --force "$n" >/dev/null 2>&1 || echo "RESTART-REFUSED (budget)"
    for i in $(seq 1 24); do
        have=$(node_run "$c" "vtysh -c 'show running-config' | grep -c 'neighbor .* remote-as'" 2>/dev/null || echo 0)
        [[ "${have//[^0-9]/}" -ge 4 ]] 2>/dev/null && break
        sleep 5
    done
    sleep 6
    loc_tab=$(node_run "$c" "vtysh -c 'show segment-routing srv6 locator'")
    echo "$loc_tab" | grep -E "loc-|Name|---" || true
    for l in "$T01" "$TV" "$TF" "loc-leaf01"; do
        c1=$(grep "$l" <<<"$loc_tab" | wc -l)
        echo "LOCATOR-AFTER-RESTART $l present=$([ "${c1:-0}" -gt 0 ] && echo yes || echo no)"
    done
    fr01b=$(grep "$T01" <<<"$loc_tab" | wc -l)
    echo "REDIS-DIRECT-CLASS persistence=$([ "${fr01b:-0}" -gt 0 ] && echo survives-restart || echo dies-with-restart)"
    fb=$(node_run "$c" "sudo docker exec bgp grep -c '$TF' /etc/frr/bgpd.conf" </dev/null)
    echo "FRR-FILE-CLASS after restart: bgpd.conf-regenerated-without-append (loc-spike-f count: $fb)"

    # cleanup: the throwaway rows must not linger in CONFIG_DB or FRR
    node_run "$c" "sudo redis-cli -n 4 DEL 'SRV6_MY_LOCATORS|$T01'" </dev/null || true
    node_run "$c" "vtysh -c 'conf t' -c 'segment-routing' -c 'srv6' -c 'locators' -c 'no locator $TV' -c 'no locator $TF' -c 'no locator $T01' -c 'end'" >/dev/null 2>&1 || true
    echo "--- throwaway rows removed (CONFIG_DB row list below) ---"
    node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_LOCATORS|*' | sort" </dev/null || true

    echo "===== $n: as-built rebuild (vpn-setup.sh re-asserts origination lost with the unit) ====="
    bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true
    echo "--- locator table (as-built) ---"
    node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" | grep -E "loc-|Name|---" || true
    node_run "$c" "vtysh -c 'show bgp ipv6 unicast fcbb:bbbb:3::/48'" 2>/dev/null \
      | grep -E 'fcbb:bbbb:3::/48|32768' | head -3 || true
    node_run "$c" "vtysh -c 'show bgp summary json'" 2>/dev/null | tr -d ' \n' | grep -o '"state":"Established"' | wc -l | sed 's/^/BGP-ESTABLISHED: /'
    cl=$C_srv6_client02
    client_run "$cl" "ping -c3 -W2 192.168.1.2" 2>/dev/null | ping_norm | tail -2 || true
fi
