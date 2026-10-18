#!/usr/bin/env bash
# T565 [US8] SRv6 capture and counter checks — ported to node_run (12-08).
#
# The feature-001 edition reached the switches two ways that do not exist on
# the default sonic-vm lab: gNMI GETs under /sonic-srv6 (the OpenConfig-style
# tree this build does not serve — the KNOWN GAP block in deploy/gnmi/
# gnmic.yaml) and docker exec into the switches themselves. Both are replaced
# here: every switch-side read goes through node_run/node_sudo (the guest ssh
# transport of tests/integration/lib/node_exec.sh), and every assertion reads
# state that actually exists on this build:
#
#   - SID counters   -> the kernel's PER-SID counters. The plan's decap op
#     installs the End.DT46 route with the seg6local `count` flag
#     (pkg/fabricplan/srv6.go), so `ip -s -6 route show` reports
#     `packets N bytes M errors 0` on the route line itself — the behavior's
#     own counters, one per service SID. (The earlier claim that per-SID
#     counters do not exist came from spike-counters §4 reading a route
#     WITHOUT the flag; falsified live 2026-10-18: enabling it made 4 pings
#     raise the route's own counter 0 -> 4 on both leaves at 0% loss. The
#     same counters are what cmd/fabric-executor/metrics.go exports as
#     fabric_executor_srv6_sid_packets_total, T560.)
#   - VRF counters   -> kernel VRF device packet counters, the coarser
#     companion granularity (fabric_executor_node_vrf_packets_total).
#   - BEHAVIORS gNMI  -> the End.DT46 route in the leaf's `ip -6 route show`,
#     which names the VRF table the service decapsulates into.
#   - SID_LIST gNMI   -> the segs list of the `encap seg6` route in the
#     service's VRF table.
#
# The busybox probe clients stay docker exec + sh -c (§8.7): clients are not
# switches.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/integration/lib/node_exec.sh
source "$ROOT_DIR/tests/integration/lib/node_exec.sh"

PROOF_DIR=${PROOF_DIR:-.wiggum/features/004-srv6-service-requests/gates/proofs}
mkdir -p "$PROOF_DIR"

SRC=${SRC:-clab-agentic-netops-fabric-srv6-client01}
DST=${DST:-clab-agentic-netops-fabric-srv6-client02}
LEAF_SRC=${LEAF_SRC:-clab-agentic-netops-fabric-leaf01}
LEAF_DST=${LEAF_DST:-clab-agentic-netops-fabric-leaf02}
PING_COUNT=${PING_COUNT:-12}

# Precondition: skip gracefully if the lab is absent (standard SKIP-LIVE
# marker, matching srv6_failover_path_change.sh / evpn_srv6_suite.sh).
for c in "$SRC" "$DST" "$LEAF_SRC" "$LEAF_DST"; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    echo "SKIP-LIVE: SRv6 capture/counter suite requires a provisioned lab ($c not present); capability gate (scripts/lib/qualify.sh) is the source of truth"
    exit 0
  fi
done

die() { echo "[srv6-capture] ERROR: $*" >&2; exit 1; }
ok()  { echo "[srv6-capture] ok: $*"; }

client_ip() { # client_ip <container> — primary IPv4 of the probe iface
  docker exec "$1" sh -c "ip addr show eth1" 2>/dev/null |
    sed -n 's/.*inet \([0-9.]*\)[ \/].*/\1/p' | head -1
}

# dt46_vrf <container> -> "<vrfdev> <vrftable>" of the leaf's own End.DT46
# function, read off the kernel route table (the decap target the service
# actually uses; nothing here consults gNMI).
dt46_vrf() {
  node_run "$1" "ip -6 route show | grep 'action End.DT46'" 2>/dev/null | head -1 |
    sed -n 's/.* action End\.DT46 vrftable \([0-9]*\) dev \([A-Za-z0-9@]*\).*/\2 \1/p'
}

# vrf_counters <container> <vrfdev> -> "rx tx" kernel packets of one VRF device
vrf_counters() {
  local rx tx
  rx=$(node_run "$1" "cat /sys/class/net/$2/statistics/rx_packets" 2>/dev/null | tail -1)
  tx=$(node_run "$1" "cat /sys/class/net/$2/statistics/tx_packets" 2>/dev/null | tail -1)
  printf '%s %s' "${rx:-0}" "${tx:-0}"
}

# sid_packets <container> -> packets counted by the leaf's own End.DT46
# behavior (the kernel per-SID counter the plan's `count` flag enables),
# read from the route line of `ip -s -6 route show`. Empty when the route
# carries no counter fields (flag not installed).
sid_packets() {
  node_run "$1" "ip -s -6 route show | grep 'action End.DT46'" 2>/dev/null | head -1 |
    sed -n 's/.*packets \([0-9]*\) bytes.*/\1/p'
}

echo "[srv6-capture] decap: read each leaf's End.DT46 function from the kernel route table"
SRC_VRF=$(dt46_vrf "$LEAF_SRC")
DST_VRF=$(dt46_vrf "$LEAF_DST")
[[ -n "$SRC_VRF" ]] || die "no action End.DT46 route on $LEAF_SRC — is an ip-vrf service provisioned?"
[[ -n "$DST_VRF" ]] || die "no action End.DT46 route on $LEAF_DST — is an ip-vrf service provisioned?"
SRC_VRFDEV=${SRC_VRF%% *}; SRC_VTBL=${SRC_VRF##* }
DST_VRFDEV=${DST_VRF%% *}; DST_VTBL=${DST_VRF##* }
echo "[srv6-capture] $LEAF_SRC decaps End.DT46 into $SRC_VRFDEV (table $SRC_VTBL); $LEAF_DST into $DST_VRFDEV (table $DST_VTBL)"

echo "[srv6-capture] segs: read the encap route's segment list from the service VRF table"
SEGS_LINE=$(node_run "$LEAF_SRC" "ip route show table $SRC_VTBL | grep 'encap seg6 mode encap'" 2>/dev/null | head -1)
[[ -n "$SEGS_LINE" ]] || die "no 'encap seg6 mode encap' route in table $SRC_VTBL on $LEAF_SRC"
echo "[srv6-capture] encap route: $SEGS_LINE"
echo "$SEGS_LINE" > "$PROOF_DIR/srv6_encap_route.txt"

# The SRH rides whatever device the encap route names (the ingress leaf's
# uplink toward the spine the underlay route chose).
CAP_DEV=$(printf '%s' "$SEGS_LINE" | sed -n 's/.* dev \([A-Za-z0-9@]*\) .*/\1/p' | head -1)
[[ -n "$CAP_DEV" ]] || die "could not read the encap route's egress device on $LEAF_SRC"

CA=$(client_ip "$SRC"); CB=$(client_ip "$DST")
[[ -n "$CA" && -n "$CB" ]] || die "probe clients have no IPv4 on eth1 ($SRC=$CA $DST=$CB)"

echo "[srv6-capture] counters: read kernel VRF packets and per-SID counters before the traffic window"
B1=$(vrf_counters "$LEAF_SRC" "$SRC_VRFDEV"); B2=$(vrf_counters "$LEAF_DST" "$DST_VRFDEV")
SB1=$(sid_packets "$LEAF_SRC"); SB2=$(sid_packets "$LEAF_DST")
echo "[srv6-capture] before: $LEAF_SRC/$SRC_VRFDEV $B1; $LEAF_DST/$DST_VRFDEV $B2; per-SID $LEAF_SRC=${SB1:-none} $LEAF_DST=${SB2:-none}"
[[ -n "$SB1" && -n "$SB2" ]] || die "a leaf's End.DT46 route carries no packets counter — the plan's seg6local \`count\` flag is not installed there (per-SID counters off, not zero)"

echo "[srv6-capture] capture: SRH-bearing outer frames on $LEAF_SRC/$CAP_DEV via node_run (guest-side tcpdump)"
CAP_TXT="$PROOF_DIR/srv6_outer_srh.txt"
node_run "$LEAF_SRC" "$(node_sudo "$LEAF_SRC") timeout 30 tcpdump -i $CAP_DEV -c 4 -t -l -nn 'ip6 and ip6[6]=43'" >"$CAP_TXT" 2>/dev/null &
CAP_PID=$!
sleep 2

echo "[srv6-capture] traffic: $PING_COUNT probes each way across the service ($CA <-> $CB)"
docker exec "$SRC" sh -c "ping -c $PING_COUNT -i 0.3 -W 2 $CB >/dev/null 2>&1" || true
docker exec "$DST" sh -c "ping -c $PING_COUNT -i 0.3 -W 2 $CA >/dev/null 2>&1" || true

wait "$CAP_PID" 2>/dev/null || true
CAP_N=$(grep -c . "$CAP_TXT" 2>/dev/null || echo 0)
echo "[srv6-capture] captured SRH frames on $CAP_DEV: $CAP_N (text in $CAP_TXT)"
head -2 "$CAP_TXT" 2>/dev/null || true
[[ "${CAP_N:-0}" -gt 0 ]] || die "no SRH-bearing frames captured on $LEAF_SRC/$CAP_DEV — the service traffic did not traverse the leaf as SRv6"
ok "SRH-bearing outer frames observed on $LEAF_SRC/$CAP_DEV"

echo "[srv6-capture] counters: read kernel VRF packets and per-SID counters after the traffic window"
A1=$(vrf_counters "$LEAF_SRC" "$SRC_VRFDEV"); A2=$(vrf_counters "$LEAF_DST" "$DST_VRFDEV")
SA1=$(sid_packets "$LEAF_SRC"); SA2=$(sid_packets "$LEAF_DST")
echo "[srv6-capture] after: $LEAF_SRC/$SRC_VRFDEV $A1; $LEAF_DST/$DST_VRFDEV $A2; per-SID $LEAF_SRC=${SA1:-none} $LEAF_DST=${SA2:-none}"
BEFORE=$(( $(echo "$B1" | cut -d' ' -f1) + $(echo "$B2" | cut -d' ' -f1) ))
AFTER=$(( $(echo "$A1" | cut -d' ' -f1) + $(echo "$A2" | cut -d' ' -f1) ))
(( AFTER > BEFORE )) || die "kernel VRF rx_packets did not increase across the traffic window ($BEFORE -> $AFTER)"
ok "kernel VRF rx_packets increased across the traffic window: $BEFORE -> $AFTER (companion VRF-device granularity)"

# The kernel per-SID counter: each leaf's own End.DT46 behavior must have
# counted the probes its client sent INTO the service (the decap is what the
# SID route does). Both leaves counted; neither may stand still.
SID_SRC_DELTA=$(( SA1 - SB1 )); SID_DST_DELTA=$(( SA2 - SB2 ))
(( SID_SRC_DELTA > 0 )) || die "kernel per-SID counter on $LEAF_SRC did not increase across the traffic window ($SB1 -> $SA1)"
(( SID_DST_DELTA > 0 )) || die "kernel per-SID counter on $LEAF_DST did not increase across the traffic window ($SB2 -> $SA2)"
ok "kernel per-SID counters increased on both leaves across the traffic window: $LEAF_SRC $SB1 -> $SA1 (+$SID_SRC_DELTA), $LEAF_DST $SB2 -> $SA2 (+$SID_DST_DELTA) (the End.DT46 behaviors' own counters — the series fabric_executor_srv6_sid_packets_total scrapes, T560)"

echo "SRV6_CAPTURE_COUNTERS_OK"
