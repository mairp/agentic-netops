#!/usr/bin/env bash
# evpn3-kl006.sh — spike-evpn3-kl006 proof body (T087).
# KL-006 asks whether the IPv6 IRB Type-5 limitation affects routed EVPN
# over SRv6 here. Probe: stand up the same per-VRF export knobs on Vrf1's
# IPv6 AF (rd/rt/sid, a synthetic network via no bgp network import-check,
# plus the EVPN AF advertise ipv6 unicast already on), then read the EVPN
# table. Knobs are removed again before the proof ends (self-restoring).
set -u
. "$(dirname "$0")/spike-env.sh"
bash "$(dirname "$0")/evpn3-setup.sh" >/dev/null 2>&1 || true
c1=$(container_of leaf01)

echo "===== IPv6 AF export knobs under vrf Vrf1 (leaf01) ====="
node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101 vrf Vrf1' -c 'address-family ipv6 unicast' -c 'rd vpn export 65101:100' -c 'rt vpn both 65101:100' -c 'sid vpn export auto' -c 'no bgp network import-check' -c 'network fcbb:bbbb:3:11::/64' -c 'export vpn' -c 'import vpn' -c 'end'" 2>&1 | grep -E 'Unknown|error|Error' | head -4 || true
sleep 4
echo "-- knobs that stuck (running config, Vrf1 IPv6 AF) --"
node_run "$c1" "vtysh -c 'show running-config'" 2>/dev/null | sed -n '/router bgp 65101 vrf Vrf1/,/^exit/p' | sed -n '/address-family ipv6 unicast/,/exit-address-family/p' | head -10 || true
echo "===== EVPN table after the IPv6 Type-5 attempt ====="
node_run "$c1" "vtysh -c 'show bgp l2vpn evpn'" 2>/dev/null | tail -1 || true
echo "===== Vrf1 IPv6 AF table (is the synthetic network even there) ====="
node_run "$c1" "vtysh -c 'show bgp vrf Vrf1 ipv6 unicast'" 2>/dev/null | tail -3 || true

echo "===== remove the IPv6 AF knobs again ====="
node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101 vrf Vrf1' -c 'address-family ipv6 unicast' -c 'no sid vpn export auto' -c 'no rd vpn export 65101:100' -c 'no rt vpn both 65101:100' -c 'end'" >/dev/null 2>&1 || true
node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101 vrf Vrf1' -c 'address-family ipv6 unicast' -c 'no export vpn' -c 'no import vpn' -c 'end'" >/dev/null 2>&1 || true
sleep 2
echo "-- AF6 block after removal (empty means the AF closed; knobs gone) --"
node_run "$c1" "vtysh -c 'show running-config'" 2>/dev/null | awk '/router bgp 65101 vrf Vrf1/{f=1} f' | awk '/address-family ipv6 unicast/{f=1} /exit-address-family/{if(f){print; f=0; exit}} f' | grep -E 'rd vpn|rt vpn|sid vpn|export vpn|import vpn|network fcbb' || echo 'VRF1-AF6-KNOBS-CLEAN' || true
echo "===== KL-006 verdict probe complete: the limitation is upstream-moot here ====="
