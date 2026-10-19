#!/usr/bin/env bash
# baseline-capture.sh <node> — spike-baseline-<node> proof body (T040-T043).
# Captures the factory state of one sonic-vm guest before any spike change:
# the running config, the routes (FRR + kernel) and the FRR daemon state.
# Read-only: everything here is a show/read command, so a re-run on an equally
# untouched lab regenerates the same bytes (FR-039): timer-shaped route ages
# and the AUTO_TECHSUPPORT "since" field are normalized (they are elapsed-time
# artifacts, not state), and daemon listing keeps only command lines.
set -u
. "$(dirname "$0")/spike-env.sh"

n=${1:?node required}
c=$(container_of "$n")
[[ -n "$c" && "$c" != 'C_'* ]] || { echo "unknown node '$n'" >&2; exit 2; }

echo "===== $n: sonic running config (show runningconfig all) ====="
# The embedded "bgpraw" field is the raw FRR config inside the JSON; it is
# creation-order unstable (see the FRR section below) and GCU itself treats it
# as noise (gu_common.py pops it). Drop the line. The DEVICE_METADATA "mac"
# field is the VM NIC's hardware address, regenerated at every deploy;
# normalize it like the other hardware-identity bytes (FR-039).
node_run "$c" "show runningconfig all" | sed -E 's/"since": "[^"]*"/"since": "NORMALIZED"/; s/("mac": ")[0-9a-f:]+(")/\1MAC-NORMALIZED\2/; /^ *"bgpraw":/d' || true

echo "===== $n: interfaces (show interface status, oper-up ports only) ====="
node_run "$c" "show interface status | awk 'NR<=2 || \$8==\"up\"'" || true

echo "===== $n: kernel addresses (data ports + loopback) ====="
# addr_norm masks the MAC-derived link-local prefixes; see spike-env.sh.
node_run "$c" "ip -br addr | grep -vE '^(Ethernet(1[6-9]|[2-9][0-9]|1[0-9][0-9])|lo|docker0)' | sort" | addr_norm || true

echo "===== $n: FRR running config ====="
# bgpcfgd-created route-map blocks (ALLOW_LIST_*, FROM/TO_BGP_PEER_*, ... +
# RM_SET_SRC*) appear in creation order, which depends on when the render ran
# relative to vtysh writes; their content is boilerplate. Drop the blocks for
# a byte-stable capture.
run_vtysh "$n" "show running-config" | sed '/^route-map /,/^exit$/d'

echo "===== $n: FRR routes (ages normalized) ====="
run_vtysh "$n" "show ip route" "show ipv6 route" | bgp_norm

echo "===== $n: kernel routes ====="
node_run "$c" "ip route; echo '-- v6 global --'; ip -6 route show scope global" | norm_volatile || true

echo "===== $n: FRR BGP state (timers normalized) ====="
# bgp_norm masks the timers/counters; the down-session State token is masked
# here: a neighbor that cannot establish (the seed's iBGP rows point at a peer
# with no matching rows) retries every `timers connect 10` seconds and its
# State/PfxRcd column flips Connect/Active at each retry — a pure timing
# artifact, unlike the stable PfxRcd numbers of established sessions (FR-039).
run_vtysh "$n" "show ip bgp summary" "show bgp ipv6 unicast summary" "show bgp l2vpn evpn summary" | bgp_norm \
  | sed -E 's/ (Active|Connect|Idle|OpenSent|OpenConfirm) / DOWN /g' \
  | sed -E 's/[[:space:]]{2,}/ /g'
# The trailing squeeze (pass 20) removes the summary table's column-alignment
# padding: the DOWN-state column width depends on how far the retrying seed
# iBGP peer got in its connect cycle, so the same DOWN row can carry 7 or 8
# spaces between runs (measured on spine02) — pure whitespace, no state.

echo "===== $n: FRR SRv6 state ====="
run_vtysh "$n" "show segment-routing srv6 locator" "show segment-routing srv6 local-sids" 2>/dev/null || true

echo "===== $n: FRR daemons (command lines only) ====="
node_run "$c" "ps -eo args | grep -E 'frr/(zebra|bgpd|fpmsyncd|staticd)' | grep -v grep | sort" || true
