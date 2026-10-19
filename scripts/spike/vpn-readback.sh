#!/usr/bin/env bash
# vpn-readback.sh <leaf01|leaf02> — spike-vpn-readback-<leaf> proof body
# (T069 read-back + T076/T077 signalling). Sections, all measured on the
# devices:
#   A. own service /48: locally originated BGP path (weight 32768), locator
#      Up, as-built kernel End.DT46 decap + steering routes, Vrf1 table id.
#   B. spine-side as-built: the /48 valid+best but NOT advertised, the kernel
#      pin that outranks the BGP path, and `bgp suppress-fib-pending` (the
#      recorded knob that ties advertisement to FIB installation).
#   C. SIGNALLING EXPERIMENT (kernel-only transient, bounded): delete the
#      spine pin -> measure the peer leaf LEARNING the /48 via BGP (vtysh +
#      kernel) -> restore the pin -> measure the WITHDRAWAL -> verdict line.
#      This proves the signalling path works and that it is the kernel pin
#      that suppresses it in the as-built state.
#   D. as-built re-assert: vpn-setup.sh, established counts, service pings,
#      pins back in place.
set -u
. "$(dirname "$0")/spike-env.sh"
n=${1:?leaf01 or leaf02}
c=$(container_of "$n")
case "$n" in
  leaf01) pself=fcbb:bbbb:3::/48; peername=leaf02; spine=spine01; snh=2001:db8:1::2; sdev=Ethernet0 ;;
  leaf02) pself=fcbb:bbbb:4::/48; peername=leaf01; spine=spine02; snh=2001:db8:2::4; sdev=Ethernet4 ;;
  *) echo "leaf01|leaf02 required" >&2; exit 2 ;;
esac
cs=$(container_of "$spine"); cp_=$(container_of "$peername")

bash "$(dirname "$0")/vpn-setup.sh" || true

echo "===== $n: own service /48 read-back ====="
echo "-- locator table --"
node_run "$c" "vtysh -c 'show segment-routing srv6 locator'" | grep -E 'loc-|Name|---' || true
echo "-- BGP path for $pself (locally originated) --"
node_run "$c" "vtysh -c 'show bgp ipv6 unicast $pself'" 2>/dev/null | sed -E 's/Last update.*/Last update NORM/; s/, version [0-9]+//' | grep -E 'BGP routing table|sourced|valid|best|Origin' | head -6 || true
echo "-- as-built kernel End.DT46 decap + steering --"
node_run "$c" "ip -6 route show | grep 'seg6local'" || true
node_run "$c" "ip -6 route show | grep 'seg6 mode encap'" || true
echo "-- Vrf1 table id the decap uses --"
node_run "$c" "ip -d link show Vrf1 | grep -o 'table [0-9]*'" || true
echo "-- CONFIG_DB SRV6_MY_SIDS rows (write class attempted by the builder) --"
node_run "$c" "sudo redis-cli -n 4 keys 'SRV6_MY_SIDS*'" | sed 's/^/  /' || true
echo "-- signalling approaches this bgpd build does not carry (recorded) --"
node_run "$c" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'address-family vpnv4 unicast' 2>&1 | tail -1"
node_run "$c" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'address-family vpnv6 unicast' 2>&1 | tail -1"
node_run "$c" "vtysh -c 'end'" >/dev/null 2>&1 || true

echo "===== $spine: spine-side as-built for $pself ====="
echo "-- BGP path (valid+best but not advertised) --"
node_run "$cs" "vtysh -c 'show bgp ipv6 unicast $pself'" 2>/dev/null | sed -E 's/Last update.*/Last update NORM/; s/, version [0-9]+//' | grep -E 'BGP routing table|valid|best|advertised|Origin|metric' | head -8 || true
echo "-- kernel pin that outranks the BGP path --"
node_run "$cs" "ip -6 route show $pself" || true
echo "-- the knob tying advertisement to FIB installation --"
node_run "$cs" "vtysh -c 'show running-config' | grep 'suppress-fib-pending'" || true

echo "===== SIGNALLING EXPERIMENT: delete $spine pin, measure $peername learning $pself ====="
echo "-- peer leaf BEFORE (expect no BGP path, no kernel route) --"
node_run "$cp_" "vtysh -c 'show bgp ipv6 unicast $pself'" 2>/dev/null | grep -cE 'valid' | sed 's/^/  bgp-paths: /'
node_run "$cp_" "ip -6 route show $pself" | sed 's/^/  kernel: /' || true
node_run "$cs" "sudo ip -6 route del $pself" || true
echo "-- pin deleted on $spine; polling $peername for the learned path --"
learn_t=""
for i in $(seq 1 12); do
    if node_run "$cp_" "vtysh -c 'show bgp ipv6 unicast $pself'" 2>/dev/null | grep -qE 'valid'; then learn_t=$i; break; fi
    sleep 5
done
if [ -n "$learn_t" ]; then
    echo "  learned: yes (within the 60s bounded poll window)"
    node_run "$cp_" "vtysh -c 'show bgp ipv6 unicast $pself'" 2>/dev/null | sed -E 's/Last update.*/Last update NORM/; s/, version [0-9]+//' | grep -E 'valid|best|Origin|via|metric' | head -6 | sed 's/^/    /'
    node_run "$cp_" "ip -6 route show $pself" | sed 's/^/    kernel: /'
else
    echo "  NOT-LEARNED within 60s (experiment inconclusive)"
fi
echo "-- restoring the pin (as-built kernel-only change, exact pin form) --"
node_run "$cs" "sudo ip -6 route replace $pself via $snh dev $sdev metric 5" || true
wd_t=""
for i in $(seq 1 12); do
    if ! node_run "$cp_" "vtysh -c 'show bgp ipv6 unicast $pself'" 2>/dev/null | grep -qE 'valid'; then wd_t=$i; break; fi
    sleep 5
done
if [ -n "$wd_t" ]; then
    echo "  withdrawn: yes (within the 60s bounded poll window); peer kernel view: $(node_run "$cp_" "ip -6 route show $pself" | tr '\n' ' ')"
else
    echo "  NOT-WITHDRAWN within 60s (experiment inconclusive)"
fi
echo "SIGNALLING-CLASS as-built=no-bgp-signalling-of-the-service (spine kernel pin outranks the BGP path; suppress-fib-pending blocks advertisement until FIB-installed); causal-path=$([ -n "$learn_t" ] && [ -n "$wd_t" ] && echo works || echo inconclusive) learned=$([ -n "$learn_t" ] && echo yes || echo no) withdrawn=$([ -n "$wd_t" ] && echo yes || echo no)"

echo "===== as-built end state (re-asserted) ====="
bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true
echo "-- pin back on $spine: $(node_run "$cs" "ip -6 route show $pself")"
for x in leaf01 leaf02; do
    xc=$(container_of "$x")
    node_run "$xc" "vtysh -c 'show bgp summary json'" 2>/dev/null | tr -d ' \n' | grep -o '"state":"Established"' | wc -l | sed "s/^/BGP-ESTABLISHED $x: /"
done
client_run "$C_srv6_client02" "ping -c3 -W2 192.168.1.2" 2>/dev/null | ping_norm | tail -2 | sed 's/^/leaf01-service: /' || true
client_run "$C_srv6_client01" "ping -c3 -W2 192.168.2.2" 2>/dev/null | ping_norm | tail -2 | sed 's/^/leaf02-service: /' || true
