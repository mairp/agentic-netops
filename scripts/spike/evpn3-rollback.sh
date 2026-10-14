#!/usr/bin/env bash
# evpn3-rollback.sh — spike-evpn3-rollback proof body (T088).
# Removes everything the routed-EVPN attempt added, restoring the device to
# the §2 as-built state, then asserts: no EVPN neighbours or AFs remain, the
# EVPN/VNI config is gone, the L3VNI device is gone, the client traffic
# passes again (8900-byte DF both directions), and the node locator is
# untouched (FR-006: a service experiment never changes a locator).
set -u
. "$(dirname "$0")/spike-env.sh"
. "$(dirname "$0")/evpn3-lib.sh"
bash "$(dirname "$0")/evpn3-setup.sh" >/dev/null 2>&1 || true
c1=$(container_of leaf01); c2=$(container_of leaf02)
cl01=$C_srv6_client01; cl02=$C_srv6_client02

echo "===== EVPN AF down on the fabric sessions ====="
node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'address-family l2vpn evpn' -c 'no neighbor 10.1.0.0 activate' -c 'no neighbor 10.1.0.4 activate' -c 'no advertise-all-vni' -c 'no advertise ipv4 unicast' -c 'no advertise ipv6 unicast' -c 'end'" >/dev/null 2>&1 || true
node_run "$c2" "vtysh -c 'conf t' -c 'router bgp 65102' -c 'address-family l2vpn evpn' -c 'no neighbor 10.1.0.2 activate' -c 'no neighbor 10.1.0.6 activate' -c 'no advertise-all-vni' -c 'no advertise ipv4 unicast' -c 'no advertise ipv6 unicast' -c 'end'" >/dev/null 2>&1 || true
for n in spine01 spine02; do
    c=$(container_of "$n")
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp 65000' -c 'address-family l2vpn evpn' -c 'no neighbor 10.1.0.1 activate' -c 'no neighbor 10.1.0.5 activate' -c 'no neighbor 10.1.0.3 activate' -c 'no neighbor 10.1.0.7 activate' -c 'no neighbor 10.1.0.1 route-reflector-client' -c 'no neighbor 10.1.0.5 route-reflector-client' -c 'no neighbor 10.1.0.3 route-reflector-client' -c 'no neighbor 10.1.0.7 route-reflector-client' -c 'end'" >/dev/null 2>&1 || true
done

echo "===== drop the leaf-leaf locator EVPN session ====="
node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'no neighbor fcbb:bbbb:4::1' -c 'end'" >/dev/null 2>&1 || true
node_run "$c2" "vtysh -c 'conf t' -c 'router bgp 65102' -c 'no neighbor fcbb:bbbb:3::1' -c 'end'" >/dev/null 2>&1 || true

echo "===== drop the per-VRF and default-VRF export knobs ====="
undo_vrf() { # $1 node $2 asn
    local c; c=$(container_of "$1")
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2 vrf Vrf1' -c 'address-family ipv4 unicast' -c 'no rd vpn export $2:100' -c 'no rt vpn both $2:100' -c 'no sid vpn export auto' -c 'no export vpn' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2 vrf Vrf1' -c 'address-family ipv4 unicast' -c 'no export vpn' -c 'no import vpn' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2' -c 'address-family ipv4 unicast' -c 'no rd vpn export $2:100' -c 'no rt vpn both $2:100' -c 'no sid vpn export auto' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2' -c 'address-family ipv4 unicast' -c 'no export vpn' -c 'no import vpn' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'vrf Vrf1' -c 'no vni 1001' -c 'end'" >/dev/null 2>&1 || true
}
undo_vrf leaf01 65101
undo_vrf leaf02 65102

echo "===== remove the L3VNI devices ====="
node_run "$c1" "sudo ip link del vxlan-1001 2>/dev/null; ip link show vxlan-1001 2>&1 | head -1" || true
node_run "$c2" "sudo ip link del vxlan-1001 2>/dev/null; ip link show vxlan-1001 2>&1 | head -1" || true

sleep 4
echo "===== assert: EVPN AF carries no neighbours, no VNI, no routes ====="
node_run "$c1" "vtysh -c 'show bgp l2vpn evpn summary'" 2>/dev/null | tail -1 || true
node_run "$c1" "vtysh -c 'show bgp l2vpn evpn'" 2>/dev/null | tail -1 || true
node_run "$c1" "vtysh -c 'show evpn vni'" 2>/dev/null | tail -1 || true
node_run "$c2" "vtysh -c 'show bgp l2vpn evpn summary'" 2>/dev/null | tail -1 || true

echo "===== assert: Vrf1 back to the §2 as-built state ====="
node_run "$c1" "ip route show vrf Vrf1 | grep '192.168.2.0'; ip -6 route show | grep 'fcbb:bbbb:3:11'" || true
node_run "$c2" "ip route show vrf Vrf1 | grep '192.168.1.0'; ip -6 route show | grep 'fcbb:bbbb:4:11'" || true

echo "===== assert: client traffic passes again (8900-byte DF, both directions) ====="
client_run "$cl01" "ping -c3 -W3 -s 8900 -M do 192.168.2.2 2>&1 | tail -2" | ping_norm || true
client_run "$cl02" "ping -c3 -W3 -s 8900 -M do 192.168.1.2 2>&1 | tail -2" | ping_norm || true

echo "===== assert: client subnets OUT of the default tables (isolation restored) ====="
echo "-- leaf01: $(evpn3_leak_state leaf01)"
echo "-- leaf02: $(evpn3_leak_state leaf02)"
echo "-- spine01: $(node_run "$(container_of spine01)" "ip route show | grep -q '192.168' && echo CLIENT-ROUTES-PRESENT || echo CLEAN" 2>/dev/null) (expect CLEAN)"

echo "===== assert: node locators untouched (FR-006) ====="
node_run "$c1" "vtysh -c 'show running-config'" 2>/dev/null | sed -n '/segment-routing/,/^!/p' | grep -E 'locator|prefix' | head -3 || true
node_run "$c2" "vtysh -c 'show running-config'" 2>/dev/null | sed -n '/segment-routing/,/^!/p' | grep -E 'locator|prefix' | head -3 || true
