#!/usr/bin/env bash
# underlay-apply.sh <node> — spike-underlay-apply-<node> proof body
# (T048-T055). Applies ONE node's identity and fabric addressing through the
# GCU write path (generic_config_updater on the guest, the path the 202505
# YANG accepts):
#   1. removes the factory INTERFACE / BGP_NEIGHBOR / LOOPBACK_INTERFACE rows
#      (whole-table remove + re-add, so stale rows cannot survive),
#   2. sets DEVICE_METADATA hostname/bgp_asn/bgp_router_id (data-model §7),
#   3. adds this node's /31 + /127 fabric addresses on Ethernet0/Ethernet4 and
#      the loopback, plus one BGP_NEIGHBOR row per peer per address family.
# Idempotent by construction (whole-table re-adds of exactly the declared
# intent), so a replay reproduces the same read-backs (FR-039). BGP session
# state is deliberately NOT captured here: during the rollout a node's
# neighbors come up as later nodes are applied, which would make this proof's
# output depend on rollout order. Session establishment and reachability are
# asserted by spike-underlay-v4 / spike-underlay-v6, run after all four nodes.
set -u
. "$(dirname "$0")/spike-env.sh"

n=${1:?node required}
c=$(container_of "$n")
asn=$(fabric_field "$n" 2); lo4=$(fabric_field "$n" 3); lo6=$(fabric_field "$n" 4)
[[ -n "$asn" ]] || { echo "unknown node '$n'" >&2; exit 2; }

# Guest-side applier: reads the plan for this node from /tmp/.spike_peers.json.
cat > /tmp/.spike_underlay.py <<'PY'
import json, sys
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch

node, asn, lo4, lo6 = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
peers = json.load(open("/tmp/.spike_peers.json"))

iface = {}
nbr = {}
for p in peers:
    if not p.get("bgponly"):
        # INTERFACE rows carry no fields on this image: admin_status is a PORT
        # field (ports are factory admin-up), and an unknown field makes the
        # YANG loader reject the whole INTERFACE table (measured: "All Keys
        # are not parsed in INTERFACE").
        iface[p["if"]] = {}
        iface[p["if"] + "|" + p["v4"]] = {}
        iface[p["if"] + "|" + p["v6"]] = {}
    nbr[p["peer4"]] = {"asn": str(p["asn"]), "local_addr": p["loc4"],
                       "holdtime": "180", "keepalive": "60", "nhopself": "0", "rrclient": "0"}
    nbr[p["peer6"]] = {"asn": str(p["asn"]), "local_addr": p["loc6"],
                       "holdtime": "180", "keepalive": "60", "nhopself": "0", "rrclient": "0"}

lo = {"Loopback0": {}, "Loopback0|" + lo4 + "/32": {}, "Loopback0|" + lo6 + "/128": {}}
# Each remove/add pair is its own JsonPatch and each failure is tolerated:
# GCU aborts a whole patch on the first failing op, and a remove of a table
# that is already absent (e.g. after spike-factory-<node>) must not stop the
# adds - measured: the adds silently never ran in that case.
ops = [
    [{"op": "remove", "path": "/INTERFACE"}],
    [{"op": "add", "path": "/INTERFACE", "value": iface}],
    [{"op": "remove", "path": "/LOOPBACK_INTERFACE"}],
    [{"op": "add", "path": "/LOOPBACK_INTERFACE", "value": lo}],
    [{"op": "remove", "path": "/BGP_NEIGHBOR"}],
    [{"op": "add", "path": "/BGP_NEIGHBOR", "value": nbr}],
    [{"op": "add", "path": "/DEVICE_METADATA/localhost/hostname", "value": node}],
    [{"op": "add", "path": "/DEVICE_METADATA/localhost/bgp_asn", "value": asn}],
    [{"op": "add", "path": "/DEVICE_METADATA/localhost/bgp_router_id", "value": lo4}],
    # 202505's bgpd template advertises the IPv6 loopback as the /64 covering
    # it unless this knob is set (bgpd.main.conf.j2:
    # "bgp_adv_lo_prefix_as_128" -> "network .../128"). Measured before the
    # knob: every node originated the same 2001:db8:ff::/64 and no /128
    # reached any peer, so v6 loopbacks were unreachable.
    [{"op": "add", "path": "/DEVICE_METADATA/localhost/bgp_adv_lo_prefix_as_128", "value": "true"}],
]
for chunk in ops:
    try:
        GenericUpdater().apply_patch(JsonPatch(chunk), ConfigFormat.CONFIGDB, False, False, False, [])
    except Exception:
        # GCU's immediate read-after-write verification can race the managers
        # on this image; the CONFIG_DB read-back in the proof is the check.
        print("APPLY-EXCEPTION (see CONFIG_DB read-back below)", file=sys.stderr)
print("APPLIED %s asn=%s lo4=%s lo6=%s ifaces=%d nbrs=%d" %
      (node, asn, lo4, lo6, len(iface), len(nbr)))
PY

fabric_field "$n" 5 | python3 -c '
import json, sys
out = []
for spec in sys.stdin.read().strip().split(";"):
    iface, lip, pip, pasn, lip6, pip6 = spec.split(",")
    out.append({"if": iface, "v4": lip+"/31", "loc4": lip, "peer4": pip,
                "v6": lip6+"/127", "loc6": lip6, "peer6": pip6, "asn": int(pasn)})
# The spines are not directly linked, so a spine cannot learn the other
# spine'"'"'s loopback from a leaf: the leaf re-advertises it with AS path
# "<leaf-as> 65000", which the receiving spine drops as an AS loop (measured).
# A spine-to-spine iBGP session over the loopbacks carries it cleanly; this is
# the standard CLOS peering for unlinked spines and the only addition to the
# data-model §7 link list.
spine_lo = {"spine01": ("10.0.0.12", "2001:db8:ff::12"),
            "spine02": ("10.0.0.11", "2001:db8:ff::11")}
if sys.argv[1] in spine_lo:
    p4, p6 = spine_lo[sys.argv[1]]
    asn = int(sys.argv[2])
    out.append({"bgponly": True, "peer4": p4, "loc4": sys.argv[3],
                "peer6": p6, "loc6": sys.argv[4], "asn": asn})
json.dump(out, open("/tmp/.spike_peers.json", "w"))' "$n" "$asn" "$lo4" "$lo6"

push_file "$c" /tmp/.spike_underlay.py /tmp/.spike_underlay.py || true
push_file "$c" /tmp/.spike_peers.json /tmp/.spike_peers.json || true

echo "===== $n: kernel IPv6 forwarding (asserted 1; sonic-vs measured 0 at boot) ====="
node_run "$c" "sudo sh -c 'echo 1 > /proc/sys/net/ipv6/conf/all/forwarding; echo 1 > /proc/sys/net/ipv4/conf/all/forwarding'; cat /proc/sys/net/ipv6/conf/all/forwarding" || true

# Spine-to-spine loopback reachability: the two spines share AS 65000 and have
# no direct link, so the other spine's loopback arrives from a leaf as
# "<leaf-as> 65000" and BGP AS-loop detection drops it. allowas-in on the
# leaf-facing neighbors is the standard same-ASN CLOS fix. The 202505 YANG has
# no CONFIG_DB field for it (grep of /usr/local/yang-models finds no allowas),
# so this piece is written through the FRR vtysh write class. It must run
# AFTER any bgpcfgd re-render below: vtysh state is live-only and a bgp
# container restart wipes it (measured), while the apply is re-run verbatim on
# every replay, keeping it re-asserted.
echo "===== $n: GCU apply (factory cleanup + identity + underlay) ====="
# GCU logs to stdout, and its immediate read-after-write verification races
# the managers on this image, so the applier's own chatter (incl. the
# APPLY-EXCEPTION token) is not stable across runs. The CONFIG_DB read-back
# below is the verification; only the APPLIED summary is surfaced.
apply_out=$(node_run "$c" "sudo python3 /tmp/.spike_underlay.py $n $asn $lo4 $lo6" 2>/dev/null || true)
grep '^APPLIED' <<<"$apply_out" || echo "APPLY-FAILED (no APPLIED line; see read-backs)"

# bgpcfgd renders /etc/frr/bgpd.conf once at bgp-unit start; a knob-only
# CONFIG_DB change does not re-render it. Restart the UNIT when the rendered
# config still carries the /64 advertisement (idempotent: after the restart
# the check goes quiet and later runs skip this). The restart goes through
# bgp_unit_restart --force: systemd (reset-failed first), never `docker
# restart bgp`, which is what trips the unit's StartLimitBurst (measured,
# leaf01 2026-10-13 21:03). Budget: >2 restarts/20 min on one node refuses.
stale64=$(node_run "$c" "sudo docker exec bgp grep -c 'network 2001:db8:ff::/64' /etc/frr/bgpd.conf" 2>/dev/null || echo 0)
if [[ "${stale64//[^0-9]/}" != "0" ]]; then
    echo "===== $n: bgpcfgd re-render (bgp unit restart for /128 knob) ====="
    bgp_unit_restart --force "$n" >/dev/null 2>&1 || true
    sleep 25
fi

# bgpd must be accepting CLI connections before any vtysh assertion; a
# container restart race here silently swallowed the assertions once
# ("Error response from daemon ... is not running", || true hid it).
# bgpd must both answer the CLI AND carry the rendered neighbors before
# any vtysh assertion: right after a (re)start bgpd runs with an empty
# config until bgpcfgd pushes CONFIG_DB, and `neighbor X allowas-in` on a
# not-yet-known peer fails with "Specify remote-as first" (silently, under
# || true). A spine has 6 neighbors (2 leaves + 1 iBGP, x v4/v6), a leaf 4.
nbrs=4; [[ "$n" == spine01 || "$n" == spine02 ]] && nbrs=6
echo "===== $n: wait for bgpd neighbors (want $nbrs) ====="
for i in $(seq 1 24); do
    have=$(node_run "$c" "vtysh -c 'show running-config' | grep -c 'neighbor .* remote-as'" 2>/dev/null || echo 0)
    [[ "${have//[^0-9]/}" -ge "$nbrs" ]] 2>/dev/null && break
    sleep 5
done

if [[ "$n" == spine01 || "$n" == spine02 ]]; then
    # The 202505 bgpd template renders the iBGP neighbor without
    # update-source, so the loopback session is sourced from a fabric
    # interface address, the peer rejects the OPEN, and the session cycles
    # Connect/Active forever (measured). vtysh assertion, live-only,
    # re-asserted on every apply.
    if [[ "$n" == spine01 ]]; then o4=10.0.0.12; o6=2001:db8:ff::12; else o4=10.0.0.11; o6=2001:db8:ff::11; fi
    echo "===== $n: vtysh allowas-in + iBGP update-source ====="
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' \
      -c 'neighbor $o4 update-source $lo4' -c 'neighbor $o6 update-source $lo6' \
      -c 'end'" >/dev/null 2>&1 || true
    leaf_peers=$(fabric_field "$n" 5 | python3 -c '
import sys
v4, v6 = [], []
for spec in sys.stdin.read().strip().split(";"):
    f = spec.split(",")
    v4.append(f[2]); v6.append(f[5])
print(" ".join(v4 + v6))')
    args=""
    for p in $leaf_peers; do args+=" -c 'neighbor $p allowas-in 1'"; done
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family ipv4 unicast' $args -c 'address-family ipv6 unicast' $args -c 'end'" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'show running-config' | grep -c 'allowas-in'" || true
fi

echo "===== $n: DEVICE_METADATA read-back (hostname bgp_asn bgp_router_id switch_type) ====="
node_run "$c" "sudo redis-cli -n 4 --raw HMGET 'DEVICE_METADATA|localhost' hostname bgp_asn bgp_router_id switch_type" || true

echo "===== $n: CONFIG_DB row read-back ====="
node_run "$c" "echo '-- INTERFACE --'; sudo redis-cli -n 4 --raw KEYS 'INTERFACE|*' | sort; echo '-- LOOPBACK_INTERFACE --'; sudo redis-cli -n 4 --raw KEYS 'LOOPBACK_INTERFACE|*' | sort; echo '-- BGP_NEIGHBOR --'; sudo redis-cli -n 4 --raw KEYS 'BGP_NEIGHBOR|*' | sort" || true

echo "===== $n: kernel address read-back ====="
node_run "$c" "ip -br addr show Ethernet0; ip -br addr show Ethernet4; ip -br addr show Loopback0" || true
