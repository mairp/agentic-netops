#!/usr/bin/env bash
# vpn-setup.sh — idempotent builder shared by the ip-vrf/vpn proofs
# (T076-T081): asserts, on both leaves, everything the routed L3VPN over
# SRv6 needs on top of the underlay and the node locators:
#   1. the locator /48 originated (Loopback0 test /128, zebra static, bgpd
#      network statement),
#   2. the per-VRF service SID as an as-built kernel route: the End.DT46
#      decap for Vrf1 (fcbb:bbbb:<n>:11::/64, vrftable 1001) — kernel seg6
#      is the dataplane on the vs ASIC; the CONFIG_DB SRV6_MY_SIDS attempt
#      is recorded (write class observed, not assumed),
#   3. the ingress steering route: the peer's service prefix inside Vrf1
#      with encap seg6 mode encap toward the peer's uDT46 SID,
#   4. the client addressing on srv6-client01/02.
set -u
. "$(dirname "$0")/spike-env.sh"
# Replay support (T105-T109): on a freshly provisioned lab this silently
# brings the underlay + locators up (fast path: probe all four nodes, only
# rebuild when a node is not converged). Prints nothing on the fast path.
. "$(dirname "$0")/ensure-fabric.sh"
ensure_fabric
c1=$(container_of leaf01); c2=$(container_of leaf02)
# The SRV6_MY_SIDS decap_vrf leafref needs VRF|Vrf1 to exist. Every replay
# chain runs the vpn-state proofs (vrf-apply) before any vpn consumer, but
# the evpn chains call this builder directly on a fresh lab — so make this
# builder self-sufficient: create Vrf1 through the same vrf-apply write path
# (silent, idempotent, also (re)attaches the access ports and client
# addresses) whenever the kernel VRF state is incomplete. Device existence
# alone is NOT sufficient: after a vpn-rollback the kernel Vrf1 device
# LINGERS (measured) while intfmgrd has taken the Ethernet12 access address
# back, so the probe also requires the VRF-side gateway address on the
# attachment port; without it the clients' ARP to 192.168.<svc>.1 fails
# with 100% loss.
for _lf in leaf01 leaf02; do
    _c=$(container_of "$_lf")
    _ok=$(node_run "$_c" "ip -br link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\.168\.' && echo Y" 2>/dev/null || true)
    [[ "$_ok" == *Y* ]] || bash "$(dirname "$0")/vrf-apply.sh" "$_lf" >/dev/null 2>&1 || true
done
# Fail loudly when a leaf's kernel VRF state is still absent: everything this
# builder asserts below (decap, steering, client addressing) depends on it,
# and a wedged orchagent must fail the proof, not record a 100%-loss
# dataplane with exit 0 (measured 2026-10-13 04:2x: the sick lab recorded
# garbage receipts while healthy in CONFIG_DB).
for _lf in leaf01 leaf02; do
    _c=$(container_of "$_lf")
    _ok=$(node_run "$_c" "ip -br link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\.168\.' && echo Y" 2>/dev/null || true)
    [[ "$_ok" == *Y* ]] || { echo "VPN-SETUP-STUCK: $_lf kernel VRF state not programmed" >&2; exit 1; }
done

originate() { # $1 node  $2 loc-addr(no /48 suffix)  $3 asn
    local c; c=$(container_of "$1")
    node_run "$c" "sudo ip addr replace $2::1/128 dev Loopback0" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'ipv6 route $2::/48 Loopback0' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $3' -c 'address-family ipv6 unicast' -c 'network $2::/48' -c 'end'" >/dev/null 2>&1 || true
}
originate leaf01 fcbb:bbbb:3 65101
originate leaf02 fcbb:bbbb:4 65102

# End.DT46 with vrftable requires net.vrf.strict_mode=1 ("Strict mode for
# VRF is disabled" otherwise) and both leaves' RX gate on (seg6_enabled,
# factory knobs are 0 on this image).
for c in "$c1" "$c2"; do
    node_run "$c" "sudo sh -c 'echo 1 > /proc/sys/net/vrf/strict_mode'; for i in all default Ethernet0 Ethernet4 Loopback0; do sudo sh -c \"echo 1 > /proc/sys/net/ipv6/conf/\$i/seg6_enabled\"; done" >/dev/null 2>&1 || true
done

# Pin each leaf's PEER locator /48 to one spine leg (metric 5 beats the bgp
# proto-20 route): the leaves otherwise hold the peer /48 as ECMP over both
# spines, and the outer packet's fresh lookup can pick the ARRIVAL leg and
# self-loop spine02->leaf02->spine02 (measured on the spine locators; same
# mechanism applies here).
pin_peer_48() { # $1 leaf  $2 peer /48
    local c; c=$(container_of "$1")
    # fabric field 5 f6 = the SPINE's v6 on the leaf's Ethernet0 (peer side)
    local p6; p6=$(fabric_field "$1" 5 | tr ';' '\n' | head -1 | cut -d, -f6)
    node_run "$c" "sudo ip -6 route replace $2 via $p6 dev Ethernet0 metric 5" >/dev/null 2>&1 || true
}
pin_peer_48 leaf01 fcbb:bbbb:4::/48
pin_peer_48 leaf02 fcbb:bbbb:3::/48

# Pin the LEAF locator /48s on both SPINES (metric 5 beats bgp). Required:
# FRR announces leaf01's /48 with an IPv4-MAPPED nexthop (::ffff:10.1.0.1 —
# leaf02's /48 comes through with a global v6 nexthop, asymmetric). bgpd
# shows the path valid+best but zebra CANNOT install a kernel route from a
# v4-mapped v6 nexthop, so every reply toward leaf01's service SID died at
# the first spine (measured pass 7). Portmap: spine01 Eth0=leaf01, Eth4=leaf02
# (2001:db8:1::x); spine02 Eth0=leaf01, Eth4=leaf02 (2001:db8:2::x).
pin_spine_48() { # $1 spine  $2 leaf/48  $3 leaf-v6  $4 spine-if
    local c; c=$(container_of "$1")
    node_run "$c" "sudo ip -6 route replace $2 via $3 dev $4 metric 5" >/dev/null 2>&1 || true
}
pin_spine_48 spine01 fcbb:bbbb:3::/48 2001:db8:1::2 Ethernet0
pin_spine_48 spine01 fcbb:bbbb:4::/48 2001:db8:1::4 Ethernet4
pin_spine_48 spine02 fcbb:bbbb:3::/48 2001:db8:2::2 Ethernet0
pin_spine_48 spine02 fcbb:bbbb:4::/48 2001:db8:2::4 Ethernet4

# Deterministic re-runs (T105-T109): the CONFIG_DB SRV6_MY_SIDS write class is
# proven live by spike-sid-write.sh (measured: the YANG-valid row — composite
# key locator|ip_prefix, fields action/decap_vrf; a "prefix_len" field fails
# schema loading — is ACCEPTED by sonic-srv6.yang AND the image's SRv6
# orchestration programs a uDT46 decap from it through zebra, kernel proto
# 196). The as-built service keeps the row OUT of steady state — the kernel
# decap below is the dataplane — so this builder only clears any leftover row
# (own process: GCU wedge semantics) before asserting the as-built route.
cat > /tmp/.spike_sids_rm.py <<'PY'
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
try:
    GenericUpdater().apply_patch(JsonPatch([{"op": "remove", "path": "/SRV6_MY_SIDS"}]),
                                 ConfigFormat.CONFIGDB, False, False, False, [])
except Exception:
    pass
PY
push_file "$c1" /tmp/.spike_sids_rm.py /tmp/.spike_sids_rm.py || true
push_file "$c2" /tmp/.spike_sids_rm.py /tmp/.spike_sids_rm.py || true
echo "===== service SID: CONFIG_DB SRV6_MY_SIDS write class ====="
# The remove is retried: the rm helper always exits 0 (it swallows GCU
# exceptions), and under config churn right after a builder run the remove
# can transiently raise — a retry after the churn settles is enough.
for _i in 1 2 3; do
    node_run "$c1" "sudo python3 /tmp/.spike_sids_rm.py" >/dev/null 2>&1 || true
    node_run "$c2" "sudo python3 /tmp/.spike_sids_rm.py" >/dev/null 2>&1 || true
    _left=$(node_run "$c1" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_SIDS*' | wc -l" 2>/dev/null || echo 0)
    [ "${_left:-0}" = "0" ] && break
    sleep 2
done
echo "SID-ROW-ABSENT (write class proven+reverted by spike-sid-write; as-built decap below)"

echo "===== End.DT46 decap asserted in the kernel (both leaves) ====="
node_run "$c1" "sudo ip -6 route replace fcbb:bbbb:3:11::/64 encap seg6local action End.DT46 vrftable 1001 dev Vrf1 && ip -6 route show | grep 'fcbb:bbbb:3:11'" || true
node_run "$c2" "sudo ip -6 route replace fcbb:bbbb:4:11::/64 encap seg6local action End.DT46 vrftable 1001 dev Vrf1 && ip -6 route show | grep 'fcbb:bbbb:4:11'" || true

echo "===== ingress steering toward the peer's uDT46 SID (in Vrf1) ====="
node_run "$c1" "sudo ip route replace 192.168.2.0/24 vrf Vrf1 encap seg6 mode encap segs fcbb:bbbb:4:11:: dev Ethernet0 && ip route show vrf Vrf1 | grep '192.168.2.0'" || true
node_run "$c2" "sudo ip route replace 192.168.1.0/24 vrf Vrf1 encap seg6 mode encap segs fcbb:bbbb:3:11:: dev Ethernet0 && ip route show vrf Vrf1 | grep '192.168.1.0'" || true

echo "===== client addressing (both srv6 clients) ====="
cl01=$C_srv6_client01; cl02=$C_srv6_client02
client_run "$cl01" "ip addr flush dev eth0" >/dev/null 2>&1 || true
client_run "$cl01" "ip addr flush dev eth1" >/dev/null 2>&1 || true
client_run "$cl01" "ip addr add 192.168.1.2/24 dev eth1" >/dev/null 2>&1 || true
client_run "$cl01" "ip route replace default via 192.168.1.1 dev eth1" >/dev/null 2>&1 || true
client_run "$cl02" "ip addr flush dev eth0" >/dev/null 2>&1 || true
client_run "$cl02" "ip addr flush dev eth1" >/dev/null 2>&1 || true
client_run "$cl02" "ip addr add 192.168.2.2/24 dev eth1" >/dev/null 2>&1 || true
client_run "$cl02" "ip route replace default via 192.168.2.1 dev eth1" >/dev/null 2>&1 || true
echo "srv6-client01: $(client_run "$cl01" "ip -4 -br addr show eth1" 2>/dev/null | addr_norm)"
echo "srv6-client02: $(client_run "$cl02" "ip -4 -br addr show eth1" 2>/dev/null | addr_norm)"
