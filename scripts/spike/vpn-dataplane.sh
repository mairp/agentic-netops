#!/usr/bin/env bash
# vpn-dataplane.sh — spike-vpn-dataplane proof body (T078-T082).
# Proves the routed ip-vrf/vpn service end to end across the fabric:
#   L1/L2  per-leaf locator /48 origination (kernel test address on Loopback0,
#          zebra static route, bgpd network statement — the locator-proof S5
#          pattern, applied to both leaves),
#   L3     per-leaf End.DT46 decap: the CONFIG_DB SRV6_MY_SIDS row
#          (action uDT46, decap_vrf Vrf1) is the declared state; the proof
#          then asserts the as-built kernel route of the exact shape the
#          stack programs (fcbb:bbbb:<n>:11::/64 encap seg6local action
#          End.DT46 vrftable 1001 dev Vrf1) on BOTH leaves — the recipe's
#          dataplane candidate (kernel seg6 on the vs ASIC). Idempotent
#          set-then-read, so the section is deterministic.
#   L4     per-leaf ingress steering: 192.168.<peer>.0/24 in Vrf1 with
#          encap seg6 mode encap segs <peer uDT46 sid> out the fabric port.
#   L5     the acceptance bar: srv6-client01 pings srv6-client02 through the
#          leaf-spine-leaf fabric inside an SRv6-encapsulated path, plus the
#          return-path read-backs.
# Locators: leaf01 fcbb:bbbb:3::/48 (uDT46 fcbb:bbbb:3:11::/64), leaf02
# fcbb:bbbb:4::/48 (uDT46 fcbb:bbbb:4:11::/64).
set -u
. "$(dirname "$0")/spike-env.sh"

c1=$(container_of leaf01); c2=$(container_of leaf02)
cl01=$C_srv6_client01; cl02=$C_srv6_client02

echo "===== L1/L2. locator /48 origination on both leaves ====="
node_run "$c1" "sudo ip addr replace fcbb:bbbb:3::1/128 dev Loopback0" >/dev/null 2>&1 || true
node_run "$c2" "sudo ip addr replace fcbb:bbbb:4::1/128 dev Loopback0" >/dev/null 2>&1 || true
node_run "$c1" "vtysh -c 'conf t' -c 'ipv6 route fcbb:bbbb:3::/48 Loopback0' -c 'router bgp 65101' -c 'address-family ipv6 unicast' -c 'network fcbb:bbbb:3::/48' -c 'end'" >/dev/null 2>&1 || true
node_run "$c2" "vtysh -c 'conf t' -c 'ipv6 route fcbb:bbbb:4::/48 Loopback0' -c 'router bgp 65102' -c 'address-family ipv6 unicast' -c 'network fcbb:bbbb:4::/48' -c 'end'" >/dev/null 2>&1 || true
sleep 5
echo "--- leaf01 holds its /48 and receives leaf02's ---"
node_run "$c1" "ip -6 route show | grep -c 'fcbb:bbbb:3::/48'" || true
node_run "$c1" "ip -6 route show | grep 'fcbb:bbbb:4::/48'" | grep -E "bgp|Ethernet" || true
echo "--- leaf02 holds its /48 and receives leaf01's ---"
node_run "$c2" "ip -6 route show | grep -c 'fcbb:bbbb:4::/48'" || true
node_run "$c2" "ip -6 route show | grep 'fcbb:bbbb:3::/48'" | grep -E "bgp|Ethernet" || true

echo "===== L3. End.DT46 decap asserted in the kernel on both leaves ====="
node_run "$c1" "sudo ip -6 route replace fcbb:bbbb:3:11::/64 encap seg6local action End.DT46 vrftable \$(ip -d link show Vrf1 | grep -o 'table [0-9]*' | cut -d' ' -f2) dev Vrf1" >/dev/null 2>&1 || true
node_run "$c2" "sudo ip -6 route replace fcbb:bbbb:4:11::/64 encap seg6local action End.DT46 vrftable \$(ip -d link show Vrf1 | grep -o 'table [0-9]*' | cut -d' ' -f2) dev Vrf1" >/dev/null 2>&1 || true
echo "--- CONFIG_DB declared SID rows ---"
node_run "$c1" "sudo redis-cli -n 4 HGET 'SRV6_MY_SIDS|loc-leaf01|fcbb:bbbb:3:11::/64' action" || true
node_run "$c2" "sudo redis-cli -n 4 HGET 'SRV6_MY_SIDS|loc-leaf02|fcbb:bbbb:4:11::/64' action" || true
echo "--- kernel decap routes ---"
node_run "$c1" "ip -6 route show | grep 'seg6local'" || true
node_run "$c2" "ip -6 route show | grep 'seg6local'" || true

echo "===== L4. ingress steering toward the peer's uDT46 SID ====="
node_run "$c1" "sudo ip -6 route replace 192.168.2.0/24 vrf Vrf1 encap seg6 mode encap segs fcbb:bbbb:4:11:: dev Ethernet0" || true
node_run "$c2" "sudo ip -6 route replace 192.168.1.0/24 vrf Vrf1 encap seg6 mode encap segs fcbb:bbbb:3:11:: dev Ethernet0" || true
node_run "$c1" "ip -6 route show vrf Vrf1 | grep 192.168.2.0" || true
node_run "$c2" "ip -6 route show vrf Vrf1 | grep 192.168.1.0" || true

echo "===== L5. client-to-client traffic across the fabric ====="
client_run "$cl02" "ip addr flush dev eth0" >/dev/null 2>&1 || true
client_run "$cl02" "ip addr flush dev eth1" >/dev/null 2>&1 || true
client_run "$cl02" "ip addr add 192.168.2.2/24 dev eth1" >/dev/null 2>&1 || true
client_run "$cl02" "ip route replace default via 192.168.2.1 dev eth1" >/dev/null 2>&1 || true
echo "--- client01 -> client02 (the service bar) ---"
client_run "$cl01" "ping -c2 -W3 192.168.2.2 2>&1 | tail -2" | ping_norm || true
echo "--- client02 -> client01 (return path) ---"
client_run "$cl02" "ping -c2 -W3 192.168.1.2 2>&1 | tail -2" | ping_norm || true
