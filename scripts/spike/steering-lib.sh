#!/usr/bin/env bash
# steering-lib.sh — shared helpers for the preferred-spine steering spike
# (T096-T100). The per-service mechanism: a /64 route to the peer's End.DT46
# function space per leaf, preferred via the node's spine01 leg (metric 5) and
# backed by the spine02 leg (metric 20) — the kernel picks 5 over 20, so the
# service rides the preferred spine until that path dies.
#
# Measured launcher<->guest map (spike-portmap-leaf01): launcher eth1 <-> guest
# Ethernet0 (spine01 leg), launcher eth2 <-> guest Ethernet4 (spine02 leg).
steer_on() {
    local c1 c2
    c1=$(container_of leaf01); c2=$(container_of leaf02)
    # The pins are ZEBRA static routes (not raw `ip`): zebra reinstalls a
    # static route when its egress link returns, so the preferred path comes
    # back after a failover window without any manual re-plumbing.
    node_run "$c1" "vtysh -c 'conf t' -c 'ipv6 route fcbb:bbbb:4:11::/64 2001:db8:1::3 Ethernet0 5' -c 'ipv6 route fcbb:bbbb:4:11::/64 2001:db8:2::3 Ethernet4 20' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c2" "vtysh -c 'conf t' -c 'ipv6 route fcbb:bbbb:3:11::/64 2001:db8:1::5 Ethernet0 5' -c 'ipv6 route fcbb:bbbb:3:11::/64 2001:db8:2::5 Ethernet4 20' -c 'end'" >/dev/null 2>&1 || true
}
steer_off() {
    # Removal needs the EXACT argument form: argument-less `no ipv6 route`
    # is a silent no-op in this FRR build (measured).
    local c1 c2
    c1=$(container_of leaf01); c2=$(container_of leaf02)
    node_run "$c1" "vtysh -c 'conf t' -c 'no ipv6 route fcbb:bbbb:4:11::/64 2001:db8:1::3 Ethernet0 5' -c 'no ipv6 route fcbb:bbbb:4:11::/64 2001:db8:2::3 Ethernet4 20' -c 'end'" >/dev/null 2>&1 || true
    node_run "$c2" "vtysh -c 'conf t' -c 'no ipv6 route fcbb:bbbb:3:11::/64 2001:db8:1::5 Ethernet0 5' -c 'no ipv6 route fcbb:bbbb:3:11::/64 2001:db8:2::5 Ethernet4 20' -c 'end'" >/dev/null 2>&1 || true
}
# path_readback <leaf> — kernel FIB choice for the PEER's function space
# (leaf01 queries leaf02's 4:11; leaf02 queries leaf01's 3:11 — querying the
# own function space would just hit the local End.DT46 decap route).
path_readback() {
    case "$1" in
        leaf01) local dst=fcbb:bbbb:4:11:: ;;
        *)      local dst=fcbb:bbbb:3:11:: ;;
    esac
    node_run "$(container_of "$1")" "ip -6 route get $dst" 2>/dev/null | head -1
}
# probe_loss_class <client> <peer-ip> — analyse the 20-probe 1 Hz window that
# the caller ran into /tmp/sf.ping inside the client container, and print ONLY
# classifiers: the raw missed/run numbers are measured state for docs
# data-model §8.6, never printed, so the proof replay stays byte-stable.
probe_loss_class() {
    local cl=$1 ip=$2 out sent rcvd lost
    out=$(docker exec "$cl" sh -c "cat /tmp/sf.ping 2>/dev/null" || true)
    sent=$(awk -F'[ ,]+' '/packets transmitted/{print $1}' <<<"$out")
    rcvd=$(awk -F'[ ,]+' '/packets transmitted/{print $4}' <<<"$out")
    sent=${sent:-0}; rcvd=${rcvd:-0}
    lost=$((sent - rcvd))
    local longest=0 run=0 prev=0 seq s
    while read -r seq; do
        seq=${seq#icmp_seq=}
        [ -z "$seq" ] && continue
        if [ "$seq" -eq "$((prev + 1))" ]; then run=$((run + 1)); else run=1; fi
        [ "$run" -gt "$longest" ] && longest=$run
        prev=$seq
    done < <(grep -o 'icmp_seq=[0-9]*' <<<"$(grep 'no answer yet' <<<"$out" || true)")
    echo "PROBES: $sent at 1 Hz"
    if [ "$lost" -le 10 ] && [ "$longest" -le 10 ]; then
        echo "LOSS-BOUNDED: yes (missed<=10, longest-run<=10)"
    else
        echo "LOSS-BOUNDED: NO (exceeds the 10-probe bound)"
    fi
}
