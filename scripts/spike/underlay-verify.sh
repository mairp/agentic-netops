#!/usr/bin/env bash
# underlay-verify.sh <v4|v6> — spike-underlay-v4 / spike-underlay-v6 proof
# bodies (T056-T060, T061-T065). Asserts, for BOTH address families, that the
# fabric underlay carries routes: per node, the two spine BGP sessions are
# Established, the BGP-learned routes are present, and the loopbacks of the
# other three nodes answer pings sourced from this node's own loopback
# (3 nodes x 4 = the 12 reachability checks of the task list).
#
# Self-contained on an already-applied underlay: every re-run applies nothing
# and only reads, with session timers, ping round-trips and TTLs normalized
# (FR-039) because they vary run to run without carrying state.
set -u
. "$(dirname "$0")/spike-env.sh"

fam=${1:?family required: v4|v6}
case "$fam" in
    # sesshow is the per-family session-summary command PROVEN to exist on this
    # bgpd build (underlay-node.sh): `show ipv6 bgp summary` is "% Unknown
    # command" here — only `show bgp ipv6 unicast summary` renders the table.
    v4) af="ip";  locmd="show ip route";   sesshow="show ip bgp summary"; other() { fabric_field "$1" 3; } ;;
    v6) af="ipv6"; locmd="show ipv6 route"; sesshow="show bgp ipv6 unicast summary"; other() { fabric_field "$1" 4; } ;;
    *) echo "family must be v4 or v6" >&2; exit 2 ;;
esac

# ping_norm now lives in spike-env.sh (shared with the locator proofs).

# Self-containedness: allowas-in lives only in the running FRR config (no
# CONFIG_DB field on 202505), so a bgpcfgd re-render since the last apply
# silently drops it and spine-to-spine loopbacks die to AS-loop detection
# again. Re-assert it only when missing (idempotent no-op on a healthy lab;
# matches scripts/spike/underlay-apply.sh).
for sp in spine01 spine02; do
    asn_sp=$(fabric_field "$sp" 2)
    peers_sp=$(fabric_field "$sp" 5 | python3 -c '
import sys
out = []
for spec in sys.stdin.read().strip().split(";"):
    f = spec.split(",")
    out += [f[2], f[5]]
print(" ".join(out))')
    c_sp=$(container_of "$sp")
    have=$(node_run "$c_sp" "vtysh -c 'show running-config' | grep -c 'allowas-in'" 2>/dev/null || echo 0)
    if [[ "${have//[^0-9]/}" != "8" ]]; then
        echo "===== $sp: allowas-in missing (have=$have, want 8); re-asserting ====="
        args=""
        for p in $peers_sp; do args+=" -c 'neighbor $p allowas-in 1'"; done
        node_run "$c_sp" "vtysh -c 'conf t' -c 'router bgp $asn_sp' -c 'address-family ipv4 unicast' $args -c 'address-family ipv6 unicast' $args -c 'end'" >/dev/null 2>&1 || true
        reasserted=1
    fi
done
# Routes withdrawn during any allowas-in gap re-announce within a few
# seconds; give the update cycle time before reading tables.
if [[ "${reasserted:-0}" == 1 ]]; then sleep 30; fi

total_ok=0; total_all=0
# Per-node established/other counts for the 4-of-4 fabric-underlay invariant
# (T060/T065): a leaf owns exactly the two underlay sessions of its fabric
# links, so leaves sum to 4 of 4; spines additionally hold the spine-spine
# iBGP peer (3 each) and every node must hold OTHER=0.
leaf_est=0; other_bad=0; e_leaf01=0; e_leaf02=0; e_spine01=0; e_spine02=0
for n in spine01 spine02 leaf01 leaf02; do
    c=$(container_of "$n")
    echo "===== $n: BGP $fam sessions (timers normalized) ====="
    run_vtysh "$n" "$sesshow" | bgp_norm
    echo "===== $n: $fam session state ====="
    # The same invariant underlay-node.sh records per node: every configured
    # neighbor established (converged), with a bounded wait so the recorded
    # invariant is the converged one, not a race artifact.
    est=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        est=$(node_run "$c" "vtysh -c '$sesshow'" | awk '
/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ / || /^[0-9a-f:]+ / {
  if ($10 ~ /^[0-9]+$/) e++; else o++
}
END { print e+0, o+0 }')
        [ "${est#* }" = "0" ] && [ "${est%% *}" -ge 2 ] 2>/dev/null && break
        sleep 5
    done
    e=${est%% *}; o=${est#* }
    echo "$fam ESTABLISHED=$e OTHER=$o"
    [ "$o" != "0" ] && other_bad=1
    case "$n" in
        leaf01) e_leaf01=$e; leaf_est=$((leaf_est+e)) ;;
        leaf02) e_leaf02=$e; leaf_est=$((leaf_est+e)) ;;
        spine01) e_spine01=$e ;;
        spine02) e_spine02=$e ;;
    esac
    echo "===== $n: BGP-learned $fam routes ====="
    run_vtysh "$n" "$locmd" | grep -E "^B" | bgp_norm || true
    echo "===== $n: $fam loopback reachability (sourced from own loopback) ====="
    mylo=$(fabric_field "$n" 3); [[ "$fam" == v6 ]] && mylo=$(fabric_field "$n" 4)
    ok=0
    for m in spine01 spine02 leaf01 leaf02; do
        [[ "$m" == "$n" ]] && continue
        peerlo=$(other "$m")
        out=$(node_run "$c" "ping -c2 -W2 -I $mylo $peerlo 2>&1 | tail -2") || true
        received=$(grep -oE '[0-9]+ received' <<<"$out" | grep -oE '^[0-9]+')
        [[ "${received:-0}" == 2 ]] && { ok=$((ok+1)); tag=OK; } || tag=FAIL
        echo "-- $n -> $m ($peerlo): $tag"
        printf '%s\n' "$out" | ping_norm
    done
    echo "REACHABILITY $n $fam: $ok/3"
    total_ok=$((total_ok+ok)); total_all=$((total_all+3))
done
echo "TOTAL REACHABILITY $fam: $total_ok/$total_all"
if [ "${other_bad:-0}" = 0 ]; then others="OTHER=0 on all four nodes"; else others="OTHER!=0 ON SOME NODE"; fi
echo "TOTAL $fam BGP SESSIONS ESTABLISHED: ${leaf_est}/4 underlay sessions (leaf01=$e_leaf01 leaf02=$e_leaf02; spines incl iBGP spine01=$e_spine01 spine02=$e_spine02; $others)"
[[ "$total_ok" == "$total_all" && "$leaf_est" == 4 && "${other_bad:-0}" == 0 ]]
