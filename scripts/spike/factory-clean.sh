#!/usr/bin/env bash
# factory-clean.sh <node> — spike-factory-<node> proof body (T048-T051).
#
# v2 (attempt 3): the first recording showed only bare redis --scan headings
# after a silent in-guest python removal, so nothing in the .out proved the
# removal class or the "own config only" end state. v2 performs the whole
# factory cycle ON DEVICE with every device-level command visible, then
# restores and asserts:
#   1. PRE-STATE  sorted CONFIG_DB keys of BGP_NEIGHBOR + INTERFACE, the
#                 per-key HGETALL dump (the node's own declared rows) and
#                 the node's established BGP session count.
#   2. REMOVE     `sudo config apply-patch` with the JSON patch
#                 [{"op":"remove","path":"/BGP_NEIGHBOR"},
#                  {"op":"remove","path":"/INTERFACE"}] — the GCU whole-table
#                 removal class a fresh-image bootstrap uses to clear the
#                 factory 64-row INTERFACE / 32-row BGP_NEIGHBOR block. The
#                 Patch Applier output is the device-level command record.
#   3. READ-BACK  independent redis read (KEYS, sorted): zero rows must
#                 remain in both tables -> FACTORY-CLEARED bgp=0 iface=0.
#   4. RESTORE    `sudo config apply-patch` with the node's own rows from 1
#                 (sonic-config JSON, built from the captured HGETALLs).
#   5. READ-BACK  key sets must equal PRE exactly (diff printed when not).
#   6. RECOVERY   bounded wait for the established session count to return,
#                 then the per-peer state table; on the leaves also the
#                 as-built service markers (locator row, End.DT46, steering)
#                 and a 3-packet client ping through the service.
set -u
. "$(dirname "$0")/spike-env.sh"
n=${1:?node required}
c=$(container_of "$n")

dump_keys() { # <node> — sorted CONFIG_DB keys of the two factory tables
    node_run "$(container_of "$1")" \
      "sudo redis-cli -n 4 --scan --pattern 'BGP_NEIGHBOR|*'; sudo redis-cli -n 4 --scan --pattern 'INTERFACE|*'" \
      2>/dev/null | sort
}

echo "===== $n: PRE-STATE (CONFIG_DB tables + established sessions) ====="
# Only measure the pre-state once the node's sessions are fully settled, so
# the recovery comparison below cannot pass against a half-converged number.
_est=$(_bgp_established "$n")
for _ in $(seq 1 30); do
    [ "${_est:-0}" -ge "$(_bgp_expected_sessions "$n")" ] 2>/dev/null && break
    sleep 4; _est=$(_bgp_established "$n")
done
pre_keys=$(dump_keys "$n")
echo "$pre_keys"
pre_count=$(echo "$pre_keys" | grep -c . || true)
est_pre=$(_bgp_established "$n")
echo "PRE-KEYS: $pre_count  BGP-ESTABLISHED: $est_pre"

# Build the node's own-rows sonic-config JSON from the captured HGETALLs.
dump_fields() { # <node> — "key<TAB>field=value" lines for every key
    local c; c=$(container_of "$1"); local k lines i
    while read -r k; do
        [ -n "$k" ] || continue
        # </dev/null: node_run must not consume the loop's stdin
        lines=$(node_run "$c" "sudo redis-cli -n 4 HGETALL '$k'" 2>/dev/null </dev/null)
        mapfile -t fl <<< "$lines"
        for ((i=0; i<${#fl[@]}-1; i+=2)); do
            [ -n "${fl[i]:-}" ] || continue
            printf '%s\t%s=%s\n' "$k" "${fl[i]}" "${fl[i+1]}"
        done
    done < <(dump_keys "$1")
}
dump_fields "$n" > /tmp/.spike_factory_dump_$n.txt
# The image's sonic-config-cli applies JSON PATCH documents only ("Document
# is expected to be sequence of operations"), and GCU validates against the
# current config, so a restore into the just-emptied tables needs the table
# itself re-added first ("member 'BGP_NEIGHBOR' not found" otherwise).
# Pointer form: /TABLE/<key-rest> with the CONFIG_DB key's inner "/" escaped
# as ~1 (measured Patch Applier path rendering: /INTERFACE/Ethernet0|10.1.0.0~131).
# Key-only INTERFACE rows (no hash fields; HGETALL prints the NULL literal)
# are restored with an empty value, exactly as the applier echoes them back.
python3 - > /tmp/.spike_factory_add_$n.json <<PYEOF
import json
rows = {}
for line in open("/tmp/.spike_factory_dump_$n.txt"):
    line = line.rstrip("\n")
    if not line:
        continue
    key, _, rest = line.partition("\t")
    field, _, value = rest.partition("=")
    if field == "NULL":
        field, value = "", ""
    rows.setdefault(key, {})[field] = value if field else ""
tables = {}
for key, fields in rows.items():
    table, _, key_rest = key.partition("|")
    tables.setdefault(table, []).append((key_rest, {k: v for k, v in fields.items() if k}))
ops = []
for table in sorted(tables):
    ops.append({"op": "add", "path": "/" + table, "value": {}})
    for key_rest, fields in sorted(tables[table]):
        pointer = "/" + table + "/" + key_rest.replace("~", "~0").replace("/", "~1")
        ops.append({"op": "add", "path": pointer, "value": fields})
print(json.dumps(ops, sort_keys=True))
PYEOF
[ -s /tmp/.spike_factory_add_$n.json ] || { echo "PRE-CAPTURE-FAILED"; exit 1; }
push_file "$c" /tmp/.spike_factory_add_$n.json /tmp/spike_factory_add.json || true

cat > /tmp/.spike_factory_rm_$n.json <<'JSON'
[{"op": "remove", "path": "/BGP_NEIGHBOR"}, {"op": "remove", "path": "/INTERFACE"}]
JSON
push_file "$c" /tmp/.spike_factory_rm_$n.json /tmp/spike_factory_rm.json || true

echo "===== $n: REMOVE factory rows (config apply-patch, Patch Applier visible) ====="
node_run "$c" "sudo config apply-patch /tmp/spike_factory_rm.json" 2>&1 \
  | grep -Ei 'patch|applied|success|error|fail|line' || true

echo "===== $n: READ-BACK after removal (independent redis read) ====="
post_rm=$(dump_keys "$n")
rm_bgp=$(echo "$post_rm" | grep -c '^BGP_NEIGHBOR' || true)
rm_if=$(echo "$post_rm" | grep -c '^INTERFACE' || true)
echo "FACTORY-CLEARED BGP_NEIGHBOR=$rm_bgp INTERFACE=$rm_if"
[ "${rm_bgp:-0}" = "0" ] && [ "${rm_if:-0}" = "0" ] || echo "FACTORY-CLEAR-INCOMPLETE"

echo "===== $n: RESTORE own config (config apply-patch, Patch Applier visible) ====="
node_run "$c" "sudo config apply-patch /tmp/spike_factory_add.json" 2>&1 \
  | grep -Ei 'patch|applied|success|error|fail|line' || true

echo "===== $n: READ-BACK after restore (must equal PRE) ====="
post_keys=$(dump_keys "$n")
if [ "$post_keys" = "$pre_keys" ]; then
    echo "OWN-CONFIG-ONLY: yes ($pre_count keys, identical to pre-state)"
else
    echo "OWN-CONFIG-ONLY: no — diff <pre post>:"
    diff <(echo "$pre_keys") <(echo "$post_keys") || true
fi
echo "--- per-key field spot check (first BGP row) ---"
first_row=$(echo "$post_keys" | grep '^BGP_NEIGHBOR' | head -1)
if [ -n "$first_row" ]; then
    node_run "$c" "sudo redis-cli -n 4 HGETALL '$first_row'" 2>/dev/null | paste - - || true
fi

echo "===== $n: RECOVERY (bounded wait for BGP sessions) ====="
# The bgpcfgd render on the row re-add rewrites /etc/frr/bgpd.conf into bgpd,
# which wipes every LIVE-ONLY vtysh assertion (underlay-apply.sh:111-119).
# On the spines that is the iBGP update-source + the leaf-facing allowas-in
# (without them the spine-spine loopback session cycles Connect/Active and
# the peer loopback route is AS-loop-dropped — measured in attempt 3); on the
# leaves it is the locator origination. The as-built recipe re-asserts them
# (underlay-apply.sh / vpn-setup.sh); the factory proof must do the same, so
# the restored node is the FULL as-built node, not just the redis rows.
asn=$(fabric_field "$n" 2); lo4=$(fabric_field "$n" 3); lo6=$(fabric_field "$n" 4)
case "$n" in
  spine*)
    peer4=$( [ "$n" = spine01 ] && echo 10.0.0.12 || echo 10.0.0.11 )
    peer6=$( [ "$n" = spine01 ] && echo 2001:db8:ff::12 || echo 2001:db8:ff::11 )
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'neighbor $peer4 update-source $lo4' -c 'neighbor $peer6 update-source $lo6' -c 'end'" >/dev/null 2>&1 || true
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
    echo "REASSERT-SPINE-VTYSH: update-source $peer4/$peer6 <- $lo4/$lo6, allowas-in on $(echo $leaf_peers | wc -w) leaf peers"
    ;;
  leaf*)
    bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true
    echo "REASSERT-LEAF-VTYSH: locator origination + service re-asserted (vpn-setup.sh)"
    ;;
esac
est=$est_pre
ok=0
for _ in $(seq 1 45); do
    est=$(_bgp_established "$n")
    [ "${est:-0}" -ge "$(_bgp_expected_sessions "$n")" ] 2>/dev/null && { ok=1; break; }
    sleep 4
done
echo "BGP-ESTABLISHED pre=$est_pre post=$est (expected $(_bgp_expected_sessions "$n"))"
node_run "$c" "vtysh -c 'show bgp summary json'" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = []
for af, v in d.items():
    if isinstance(v, dict):
        for p, s in v.get("peers", {}).items():
            rows.append("%s %s" % (p, s.get("state", "?")))
for r in sorted(rows):
    print("peer " + r)
' || true
[ "$ok" = 1 ] || echo "BGP-RECOVERY-INCOMPLETE"

case "$n" in
  leaf*)
    echo "===== $n: as-built service markers (locator/decap/steering) ====="
    node_run "$c" "sudo redis-cli -n 4 HGET 'SRV6_MY_LOCATORS|loc-${n}' prefix; ip -6 route show | grep -E 'fcbb:bbbb:.:11::/64' | head -2; ip route show vrf Vrf1 | grep '192.168' | head -2" 2>/dev/null | addr_norm || true
    echo "===== $n: client ping through the service (3 packets) ====="
    if [ "$n" = leaf01 ]; then cl=$C_srv6_client02; tgt=192.168.1.2; else cl=$C_srv6_client01; tgt=192.168.2.2; fi
    client_run "$cl" "ping -c3 -W2 $tgt" 2>/dev/null | ping_norm | tail -2 || true
    ;;
esac
echo "===== $n: DONE ====="
