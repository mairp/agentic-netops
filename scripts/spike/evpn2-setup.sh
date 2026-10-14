#!/usr/bin/env bash
# evpn2-setup.sh — idempotent builder for the bridged-EVPN (mac-vrf / L2VNI)
# attempt on top of the evpn3 attempt state (EVPN AF neighbours, RR legs,
# advertise-all-vni). Adds a minimal L2VNI: bridge br-vni + vxlan-100
# (id 100, local VTEP loopback, nolearning) on both leaves, VNI 100 in the
# bridge. zebra must see VNI 100 as L2 for bgpd to generate Type-2/3.
set -u
. "$(dirname "$0")/spike-env.sh"
bash "$(dirname "$0")/evpn3-setup.sh" >/dev/null 2>&1 || true
for _n in leaf01 leaf02 spine01 spine02; do ensure_bgp "$_n"; done
declare -A VTEP=( [leaf01]=10.0.0.21 [leaf02]=10.0.0.22 )
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    node_run "$c" "ip link show vxlan-100 >/dev/null 2>&1 || { sudo ip link add br-vni type bridge; sudo ip link add vxlan-100 type vxlan id 100 local ${VTEP[$n]} dstport 4789 nolearning; sudo ip link set vxlan-100 master br-vni; sudo ip link set br-vni up; sudo ip link set vxlan-100 up; }" >/dev/null 2>&1 || true
    # NOTE: the SONiC guest has no `bridge` binary; the vxlan id on the link
    # is sufficient for zebra to adopt the L2VNI (measured).
done
sleep 6
echo "===== evpn2 attempt state ready (leaf01 zebra VNI view) ====="
node_run "$(container_of leaf01)" "vtysh -c 'show evpn vni'" 2>/dev/null | head -5 || true
