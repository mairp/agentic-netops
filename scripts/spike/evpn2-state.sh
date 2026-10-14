#!/usr/bin/env bash
# evpn2-state.sh — spike-evpn2-state-leaf0N proof body (T092).
# Read-back of the bridged-EVPN attempt on one leaf: does zebra see the
# L2VNI (kernel truth) and does bgpd adopt it (Type-2/3 precondition)?
# The MAC-masked device greps and the classifier-only outputs are
# replay-stable by construction.
set -u
. "$(dirname "$0")/spike-env.sh"
bash "$(dirname "$0")/evpn2-setup.sh" >/dev/null 2>&1 || true
c=$(container_of "${1:-leaf01}")
echo "===== EVPN session readiness gate (up to ~60s for reconvergence) ====="
for _ in $(seq 1 30); do
    n_est=$(node_run "$c" "vtysh -c 'show bgp l2vpn evpn summary json' 2>/dev/null | grep -o '\"state\":\"Established\"' | grep -c ." 2>/dev/null)
    [ "${n_est:-0}" -ge 3 ] && break
    sleep 2
done
node_run "$c" "vtysh -c 'show bgp l2vpn evpn summary json' 2>/dev/null | grep -o '\"state\":\"Established\"' | grep -c . | awk '{printf \"EVPN-PEERS-ESTABLISHED: %s (expect 3)\n\", \$1}'" || true
echo "===== zebra VNI view (kernel L2VNI truth) ====="
node_run "$c" "vtysh -c 'show evpn vni'" 2>/dev/null | head -5 || true
echo "===== bgpd VNI view (Type-2/3 generation precondition) ====="
node_run "$c" "vtysh -c 'show bgp l2vpn evpn vni'" 2>/dev/null | grep -E 'Number of L2 VNIs|Number of L3 VNIs' || true
echo "===== EVPN table: Type-3 IMET exchange (local + remote) ====="
node_run "$c" "vtysh -c 'show bgp l2vpn evpn'" 2>/dev/null | sed -n '/Route Distinguisher/,$p' || true
echo "===== EVPN MAC table for VNI 100 (Type-2 precondition: bridge members) ====="
node_run "$c" "vtysh -c 'show evpn mac vni all' 2>/dev/null | grep -c . | awk '{printf \"MAC-ENTRIES: %s\n\", \$1}'" || true
echo "===== L2VNI kernel devices (id/local/flags only; MAC is random) ====="
node_run "$c" "ip -d link show vxlan-100 2>/dev/null | grep -oE 'vxlan id [0-9]+|local [0-9.]+|<BROADCAST,MULTICAST,UP,LOWER_UP>'; ip link show br-vni 2>/dev/null | grep -oE '<BROADCAST,MULTICAST,UP,LOWER_UP>'" || true
