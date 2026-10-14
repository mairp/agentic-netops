#!/usr/bin/env bash
# ensure-fabric.sh — silent, idempotent fabric bootstrap (replay support for
# T105-T109). Sourced by vrf-apply.sh and vpn-setup.sh so that every recorded
# proof chain re-runs self-contained on a freshly provisioned lab (T104,
# factory state) with no manual bring-up steps between replay groups.
#
# FAST PATH: one probe script per node; when the underlay and locator state
# are already converged — identity fields present, the locator row in
# CONFIG_DB *and* the FRR locator table, all BGP sessions established (a leaf
# holds 2 neighbours per family, a spine 3), and on the leaves the SRv6
# kernel gates (seg6_enabled on the fabric port, vrf strict_mode) — it prints
# NOTHING and returns 0, so every existing recorded .out stays byte-identical.
#
# SLOW PATH (fresh lab only): re-runs the recorded bootstrap builders in the
# order they were first applied, with all output discarded:
#   identity-assert (DEVICE_METADATA field-level adds + loopbacks)
#   → underlay-apply (fabric addressing + BGP_NEIGHBOR; handles the fresh-lab
#     bgpd re-render restart internally)
#   → underlay-node (bounded per-family establishment waits)
#   → kernel-prereqs (seg6 gates, vrf module, strict_mode — leaves only;
#     spines never terminate the service)
#   → locator-node (the CONFIG_DB SRV6_MY_LOCATORS GCU write class, all nodes)
# Vrf1 and the service state are deliberately NOT this helper's business:
# vrf-apply.sh creates Vrf1 itself, and every replay chain runs vrf-apply
# before any vpn consumer.
set -u
_SPIKE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

_ensure_fabric_probe() { # $1 node → prints 1 when converged, else 0
    local n=$1 c min_est
    c=$(container_of "$n")
    case "$n" in spine*) min_est=3 ;; *) min_est=2 ;; esac
    sed "s/@NODE@/$n/g; s/@MINEST@/$min_est/g" /tmp/.ensure_fabric_probe.sh > /tmp/.ensure_fabric_probe.$n.sh \
        || { echo 0; return; }
    push_file "$c" /tmp/.ensure_fabric_probe.$n.sh /tmp/.ensure_fabric_probe.$n.sh || { echo 0; return; }
    node_run "$c" "bash /tmp/.ensure_fabric_probe.$n.sh" 2>/dev/null | tail -1
}

# guest-side probe (admin shell; only redis needs sudo). Counting style is
# the proven underlay-apply invariant awk: neighbour lines start with the
# neighbour address, PfxRcd (col 10) numeric means Established.
cat > /tmp/.ensure_fabric_probe.sh <<'PROBE'
loc=$(sudo redis-cli -n 4 HGET 'SRV6_MY_LOCATORS|loc-@NODE@' prefix 2>/dev/null)
fr=$(vtysh -c 'show segment-routing srv6 locator' 2>/dev/null | grep -c "loc-@NODE@")
e4=$(vtysh -c 'show bgp ipv4 unicast summary' 2>/dev/null | awk '
/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ / || /^[0-9a-f:]+ / {
  if ($10 ~ /^[0-9]+$/) e++; else o++
}
END { print e+0 }')
e6=$(vtysh -c 'show bgp ipv6 unicast summary' 2>/dev/null | awk '
/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ / || /^[0-9a-f:]+ / {
  if ($10 ~ /^[0-9]+$/) e++; else o++
}
END { print e+0 }')
g=$(cat /proc/sys/net/ipv6/conf/Ethernet0/seg6_enabled 2>/dev/null || echo 0)
s=$(cat /proc/sys/net/vrf/strict_mode 2>/dev/null || echo 0)
ok=1
case "$loc" in fcbb:bbbb:*) ;; *) ok=0 ;; esac
[ "$fr" -ge 1 ] 2>/dev/null || ok=0
[ "$e4" -ge @MINEST@ ] 2>/dev/null || ok=0
[ "$e6" -ge @MINEST@ ] 2>/dev/null || ok=0
case "@NODE@" in leaf*) [ "$g" = 1 ] && [ "$s" = 1 ] || ok=0 ;; esac
echo "H-OK=$ok"
PROBE

ensure_fabric() {
    local ok=1 n
    for n in leaf01 leaf02 spine01 spine02; do
        [ "$(_ensure_fabric_probe "$n" | tail -1)" = "H-OK=1" ] || ok=0
    done
    [ "$ok" = 1 ] && return 0
    # SLOW PATH — all output discarded; failures tolerated, the consuming
    # builders' read-backs are the real verdicts.
    for n in leaf01 leaf02 spine01 spine02; do
        bash "$_SPIKE_DIR/identity-assert.sh" "$n" >/dev/null 2>&1 || true
        bash "$_SPIKE_DIR/underlay-apply.sh" "$n" >/dev/null 2>&1 || true
    done
    for n in leaf01 leaf02 spine01 spine02; do
        bash "$_SPIKE_DIR/underlay-node.sh" v4 "$n" >/dev/null 2>&1 || true
        bash "$_SPIKE_DIR/underlay-node.sh" v6 "$n" >/dev/null 2>&1 || true
    done
    for n in leaf01 leaf02; do
        bash "$_SPIKE_DIR/kernel-prereqs.sh" "$n" >/dev/null 2>&1 || true
    done
    for n in leaf01 leaf02 spine01 spine02; do
        bash "$_SPIKE_DIR/locator-node.sh" "$n" >/dev/null 2>&1 || true
    done
    return 0
}
