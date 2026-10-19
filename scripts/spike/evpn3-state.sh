#!/usr/bin/env bash
# evpn3-state.sh — spike-evpn3-state-leaf01 / spike-evpn3-state-leaf02 proof
# body (T083/T084). Reads back, per leaf, the whole routed-EVPN-over-SRv6
# attempt state: the EVPN session fabric (which neighbours established, over
# what transports), the L2VPN EVPN table (does ANY EVPN route exist), bgpd's
# VNI view vs zebra's (the Type-5 generation precondition), the per-VRF
# export knobs as running-config, and the L3VNI kernel device. Timers and
# counters normalized (FR-039).
set -u
. "$(dirname "$0")/spike-env.sh"
. "$(dirname "$0")/evpn3-lib.sh"
bash "$(dirname "$0")/evpn3-setup.sh" >/dev/null 2>&1 || true
c1=$(container_of leaf01); c2=$(container_of leaf02)

peer_states() { # $1 node — the EVPN session fabric, parsed from summary json
    node_run "$(container_of "$1")" "vtysh -c 'show bgp l2vpn evpn summary json'" 2>/dev/null | \
        python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('summary-json-unreadable'); sys.exit()
found=False
peers = d.get('peers') if isinstance(d.get('peers'),dict) else None
if peers is None:
    for v in d.values():
        if isinstance(v,dict) and isinstance(v.get('peers'),dict): peers=v['peers']; break
for ip,p in sorted((peers or {}).items()):
    found=True
    print('peer %s state %s pfxRcd %s' % (ip, p.get('state','?'), p.get('pfxRcd','?')))
if not found: print('no EVPN neighbours')" || true
}

for n in ${@:-leaf01 leaf02}; do
    c=$(container_of "$n")
    echo "########## $n ##########"
    echo "===== EVPN session fabric (l2vpn evpn summary json) ====="
    peer_states "$n"
    echo "===== L2VPN EVPN table ====="
    node_run "$c" "vtysh -c 'show bgp l2vpn evpn'" 2>/dev/null | tail -1 || true
    echo "===== bgpd VNI view (Type-5 generation precondition) ====="
    node_run "$c" "vtysh -c 'show bgp l2vpn evpn vni'" 2>/dev/null | sed -n '1,8p' || true
    echo "===== zebra VNI view (L3VNI tenant binding) ====="
    node_run "$c" "vtysh -c 'show evpn vni'" 2>/dev/null | tail -2 || true
    echo "===== per-VRF export knobs (running config) ====="
    node_run "$c" "vtysh -c 'show running-config'" 2>/dev/null | sed -n '/router bgp .* vrf Vrf1/,/^exit/p' | head -14 || true
    echo "===== EVPN AF knobs (running config, l2vpn evpn sections only) ====="
    node_run "$c" "vtysh -c 'show running-config'" 2>/dev/null | sed -n '/address-family l2vpn evpn/,/exit-address-family/p' | head -16 || true
    echo "===== L3VNI kernel device (id/local/flags only; MAC is random) ====="
    node_run "$c" "ip -d link show vxlan-1001 2>/dev/null | grep -oE 'vxlan id [0-9]+|local [0-9.]+|<BROADCAST,MULTICAST,UP,LOWER_UP>'" || true
    echo "===== Vrf1 own client network in the VRF AF (connected, deterministic) ====="
    node_run "$c" "vtysh -c 'show bgp vrf Vrf1 ipv4 unicast'" 2>/dev/null | grep '\*>' | grep "192.168.$([ "$n" = leaf01 ] && echo 1 || echo 2).0" || true
    echo "===== knob side effect: client subnets leaked into the DEFAULT table ====="
    evpn3_leak_state "$n"
done
