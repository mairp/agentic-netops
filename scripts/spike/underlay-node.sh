#!/usr/bin/env bash
# underlay-node.sh <v4|v6> <node> — spike-underlay-<af>-<node> proof body
# (T056-T059, T061-T064). Shows the node's two fabric-link addresses of one
# address family and that node's BGP sessions of the same family, read back
# from the device. Volatile summary fields are masked by bgp_norm (FR-039);
# the Established count is printed as a labeled invariant.
set -u
. "$(dirname "$0")/spike-env.sh"
af=${1:?v4 or v6}; n=${2:?node required}
c=$(container_of "$n")
case "$af" in
  v4) f=2; show="show bgp ipv4 unicast summary" ;;
  v6) f=5; show="show bgp ipv6 unicast summary" ;;
  *) echo "af must be v4|v6" >&2; exit 2 ;;
esac
echo "===== $n: fabric-link $af addresses ====="
if [ "$af" = v4 ]; then
  node_run "$c" "ip -4 -br addr show Ethernet0; ip -4 -br addr show Ethernet4" || true
else
  # addr_norm, not `grep -v fe80`: `ip -br` prints the link-local on the SAME
  # line as the global /127, so dropping fe80 lines dropped the /127
  # read-back itself (the T061-T064 gap). Mask the hardware-identity bytes
  # (EUI-64 link-local, MAC, host veth ifindex) instead — FR-039.
  node_run "$c" "ip -6 -br addr show Ethernet0; ip -6 -br addr show Ethernet4" | addr_norm || true
fi
echo "===== $n: BGP $af sessions ====="
node_run "$c" "vtysh -c '$show'" | grep -E "Neighbor|^10\.1\.0\.|^2001:db8" | bgp_norm || true
echo "===== $n: session state invariant ====="
# Establish happens asynchronously after the rollout; wait (bounded) so the
# recorded invariant is the converged one, not a race artifact.
# A node's summary holds exactly its configured neighbors (a leaf: the two
# spines; a spine: the two leaves plus the spine-spine iBGP peer). The
# invariant is converged only when no session is in a non-established state.
est=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
  est=$(node_run "$c" "vtysh -c '$show'" | awk '
/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ / || /^[0-9a-f:]+ / {
  if ($10 ~ /^[0-9]+$/) e++; else o++
}
END { print e+0, o+0 }')
  [ "${est#* }" = "0" ] && [ "${est%% *}" -ge 2 ] 2>/dev/null && break
  sleep 5
done
echo "$af ESTABLISHED=$(echo "$est" | cut -d" " -f1) OTHER=$(echo "$est" | cut -d" " -f2)"
