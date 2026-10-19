#!/usr/bin/env bash
# evpn3-lib.sh — shared knob add/remove for the evpn3 proofs. The per-VRF
# export knobs (rd/rt/sid vpn export, export/import vpn, network) have a
# MEASURED side effect on this build: they leak the VRF client subnets into
# the DEFAULT table through plain eBGP (the spines learn 192.168.x/24), so
# the proofs can turn just this leak off and on again to separate "traffic
# rode a leaked plain-v4 path" from "traffic rode an EVPN-signalled path".
set -u

# evpn3_leak_on <leaf> <asn> <client-net> — (re)apply the per-VRF knobs AND
# the default-instance knobs the setup stands up (approach e)
evpn3_leak_on() {
    local c; c=$(container_of "$1")
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2 vrf Vrf1' -c 'address-family ipv4 unicast' -c 'rd vpn export $2:100' -c 'rt vpn both $2:100' -c 'sid vpn export auto' -c 'network $3' -c 'export vpn' -c 'import vpn' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2' -c 'address-family ipv4 unicast' -c 'rd vpn export $2:100' -c 'rt vpn both $2:100' -c 'sid vpn export auto' -c 'export vpn' -c 'import vpn' -c 'end'" >/dev/null 2>&1 || true
}

# evpn3_leak_off <leaf> <asn> <client-net> — withdraw BOTH sets: the vrf AF
# knobs and the default-instance ones. Without the default-instance removal
# the default table keeps pulling the leaked subnets from the VPN RIB and
# the plain-v4 path survives (measured). Removal needs the EXACT arguments
# on this build: `no rd vpn export` without the RD is accepted but is a
# silent no-op, and `no sid vpn export` errors "Command incomplete".
evpn3_leak_off() {
    local c; c=$(container_of "$1")
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2 vrf Vrf1' -c 'address-family ipv4 unicast' -c 'no rd vpn export $2:100' -c 'no rt vpn both $2:100' -c 'no sid vpn export auto' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2 vrf Vrf1' -c 'address-family ipv4 unicast' -c 'no network $3' -c 'no export vpn' -c 'no import vpn' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2' -c 'address-family ipv4 unicast' -c 'no rd vpn export $2:100' -c 'no rt vpn both $2:100' -c 'no sid vpn export auto' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $2' -c 'address-family ipv4 unicast' -c 'no export vpn' -c 'no import vpn' -c 'end'" >/dev/null 2>&1 || true
}

# evpn3_leak_state <leaf> — CLASSIFIER for the leak in the DEFAULT table.
# The raw route set varies with BGP withdrawal races (1..2 lines observed),
# so the proof prints the fact, not the volatile listing.
evpn3_leak_state() {
    node_run "$(container_of "$1")" "ip route show | grep -q '192.168' && echo LEAKED-SUBNETS-IN-DEFAULT || echo DEFAULT-TABLE-CLEAN" 2>/dev/null || true
}
