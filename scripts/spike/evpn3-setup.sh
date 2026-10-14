#!/usr/bin/env bash
# evpn3-setup.sh — idempotent builder for the ip-vrf/evpn (routed EVPN over
# SRv6) attempt (T083-T088). Stands up, on the live lab, every FRR path that
# could generate an EVPN Type-5 (IP-prefix) route carrying the per-VRF SRv6
# SID, so the state/ping/capture/kl006/rollback proofs read back the same
# state every run (FR-039). The service substrate (Vrf1, kernel End.DT46,
# steering, clients) is (re)built first by vpn-setup.sh.
#
# Approaches stood up (recipe doc §3 list):
#   a. EVPN AF over the existing fabric sessions — leaves activate
#      `address-family l2vpn evpn` toward both spines, spines reflect
#      (route-reflector-client) leaf-spine-leaf;
#   b. a direct leaf-leaf EVPN eBGP session over the two locator ::1
#      addresses (the only leaf-leaf v6 the recipe proves reachable);
#   c. per-VRF Type-5 export knobs under `router bgp <asn> vrf Vrf1`:
#      rd vpn export / rt vpn both / sid vpn export auto / network /
#      export vpn / import vpn;
#   d. the L3VNI flow: `vrf Vrf1` vni 1001, `advertise-all-vni`, and a
#      real vxlan L3VNI device (zebra anchor);
#   e. the default-VRF flow: `advertise ipv4/ipv6 unicast` under the EVPN
#      AF with rd/rt/sid on the default ipv4 AF.
set -u
. "$(dirname "$0")/spike-env.sh"
bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true
for _n in leaf01 leaf02 spine01 spine02; do ensure_bgp "$_n"; done
c1=$(container_of leaf01); c2=$(container_of leaf02)

# --- a. EVPN AF on the four fabric sessions, spines as route reflectors ----
node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'address-family l2vpn evpn' -c 'neighbor 10.1.0.0 activate' -c 'neighbor 10.1.0.4 activate' -c 'end'" >/dev/null 2>&1 || true
node_run "$c2" "vtysh -c 'conf t' -c 'router bgp 65102' -c 'address-family l2vpn evpn' -c 'neighbor 10.1.0.2 activate' -c 'neighbor 10.1.0.6 activate' -c 'end'" >/dev/null 2>&1 || true
# Per-spine LEG LISTS (bug fix): the fabric /31s are spine01:10.1.0.0<->leaf01:10.1.0.1,
# spine01:10.1.0.2<->leaf02:10.1.0.3, spine02:10.1.0.4<->leaf01:10.1.0.5,
# spine02:10.1.0.6<->leaf02:10.1.0.7 — so each spine only has TWO leaf
# neighbours; activating the other spine's legs aborts the whole vtysh batch
# ("% Specify remote-as ... first") and silently drops the rr-client lines.
node_run "$(container_of spine01)" "vtysh -c 'conf t' -c 'router bgp 65000' -c 'address-family l2vpn evpn' -c 'neighbor 10.1.0.1 activate' -c 'neighbor 10.1.0.3 activate' -c 'neighbor 10.1.0.1 route-reflector-client' -c 'neighbor 10.1.0.3 route-reflector-client' -c 'end'" >/dev/null 2>&1 || true
node_run "$(container_of spine02)" "vtysh -c 'conf t' -c 'router bgp 65000' -c 'address-family l2vpn evpn' -c 'neighbor 10.1.0.5 activate' -c 'neighbor 10.1.0.7 activate' -c 'neighbor 10.1.0.5 route-reflector-client' -c 'neighbor 10.1.0.7 route-reflector-client' -c 'end'" >/dev/null 2>&1 || true

# --- b. direct leaf-leaf EVPN session over the locator ::1 addresses -------
node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'neighbor fcbb:bbbb:4::1 remote-as 65102' -c 'neighbor fcbb:bbbb:4::1 ebgp-multihop 2' -c 'neighbor fcbb:bbbb:4::1 update-source fcbb:bbbb:3::1' -c 'address-family l2vpn evpn' -c 'neighbor fcbb:bbbb:4::1 activate' -c 'end'" >/dev/null 2>&1 || true
node_run "$c2" "vtysh -c 'conf t' -c 'router bgp 65102' -c 'neighbor fcbb:bbbb:3::1 remote-as 65101' -c 'neighbor fcbb:bbbb:3::1 ebgp-multihop 2' -c 'neighbor fcbb:bbbb:3::1 update-source fcbb:bbbb:4::1' -c 'address-family l2vpn evpn' -c 'neighbor fcbb:bbbb:3::1 activate' -c 'end'" >/dev/null 2>&1 || true

# --- c. per-VRF Type-5 export knobs (both leaves, mirrored) ----------------
# rt vpn both <rt> is how FRR renders route-target vpn export+import; sid
# vpn export auto asks bgpd to allocate the per-VRF SRv6 SID from the node
# locator and attach it to the exported routes.
vrf_knobs() { # $1 node $2 asn $3 client-net
    local c; c=$(container_of "$1")
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2 vrf Vrf1' -c 'address-family ipv4 unicast' -c 'rd vpn export $2:100' -c 'rt vpn both $2:100' -c 'sid vpn export auto' -c 'network $3' -c 'export vpn' -c 'import vpn' -c 'end'" >/dev/null 2>&1 || true
}
vrf_knobs leaf01 65101 192.168.1.0/24
vrf_knobs leaf02 65102 192.168.2.0/24

# --- d. L3VNI flow ----------------------------------------------------------
# `vni 1001` binds Vrf1 to L3VNI 1001 in zebra; advertise-all-vni turns on
# the EVPN export; the vxlan device is the kernel anchor zebra needs to see
# the VNI at all (without it `show evpn vni` still lists the tenant binding
# but reports VxLAN IF None).
node_run "$c1" "vtysh -c 'conf t' -c 'vrf Vrf1' -c 'vni 1001' -c 'end'" >/dev/null 2>&1 || true
node_run "$c2" "vtysh -c 'conf t' -c 'vrf Vrf1' -c 'vni 1001' -c 'end'" >/dev/null 2>&1 || true
node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'address-family l2vpn evpn' -c 'advertise-all-vni' -c 'end'" >/dev/null 2>&1 || true
node_run "$c2" "vtysh -c 'conf t' -c 'router bgp 65102' -c 'address-family l2vpn evpn' -c 'advertise-all-vni' -c 'end'" >/dev/null 2>&1 || true
node_run "$c1" "ip link show vxlan-1001 >/dev/null 2>&1 || { sudo ip link add vxlan-1001 type vxlan id 1001 local 10.0.0.21 dstport 4789 nolearning; sudo ip link set vxlan-1001 up; }" >/dev/null 2>&1 || true
node_run "$c2" "ip link show vxlan-1001 >/dev/null 2>&1 || { sudo ip link add vxlan-1001 type vxlan id 1001 local 10.0.0.22 dstport 4789 nolearning; sudo ip link set vxlan-1001 up; }" >/dev/null 2>&1 || true

# --- e. default-VRF Type-5 flow ---------------------------------------------
node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'address-family ipv4 unicast' -c 'rd vpn export 65101:100' -c 'rt vpn both 65101:100' -c 'sid vpn export auto' -c 'export vpn' -c 'import vpn' -c 'end'" >/dev/null 2>&1 || true
node_run "$c2" "vtysh -c 'conf t' -c 'router bgp 65102' -c 'address-family ipv4 unicast' -c 'rd vpn export 65102:100' -c 'rt vpn both 65102:100' -c 'sid vpn export auto' -c 'export vpn' -c 'import vpn' -c 'end'" >/dev/null 2>&1 || true
node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'address-family l2vpn evpn' -c 'advertise ipv4 unicast' -c 'advertise ipv6 unicast' -c 'end'" >/dev/null 2>&1 || true
node_run "$c2" "vtysh -c 'conf t' -c 'router bgp 65102' -c 'address-family l2vpn evpn' -c 'advertise ipv4 unicast' -c 'advertise ipv6 unicast' -c 'end'" >/dev/null 2>&1 || true

# --- settle, then a one-line state summary ---------------------------------
sleep 8
echo "evpn3-setup applied; EVPN table: $(node_run "$c1" "vtysh -c 'show bgp l2vpn evpn' | tail -1" 2>/dev/null)"
