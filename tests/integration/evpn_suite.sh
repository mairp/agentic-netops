#!/usr/bin/env bash
# EVPN/VXLAN capability tests for the SR Linux fabric (FR-005, research D8).
#
# Required coverage: BGP EVPN Type-2 (MAC/IP), Type-3 (inclusive multicast),
# Type-5 (IP prefix), remote VTEP arrival on the bootstrap L2VNI, and overlay
# data-plane traffic between the two EVPN clients.
#
# The route assertions read the *received* side of the EVPN RIB
# (rib-in-post), never the local or advertised side. A leaf originates its own
# Type-2 and Type-3 routes, so "a Type-2 exists on this leaf" is satisfied by a
# structurally dead overlay in which nothing was ever exchanged — the previous
# fabric's gate passed that way through an entire run while the data plane had
# 100% loss. Everything here is evidence of exchange: routes that arrived from a
# peer, a remote VTEP learned from a peer's IMET, and a ping that crossed.
#
# SRv6 is deliberately absent: the SR Linux 7220 container has no SRv6 data
# plane. The capability gate records SRv6 entries as `not-applicable` with that
# reason rather than skipping them silently (constitution II).
set -euo pipefail

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_ENCODING=${GNMI_ENCODING:-json_ietf}
LEAVES=${LEAVES:-"172.31.0.21:57400,172.31.0.22:57400"}
CLAB_PREFIX=${CLAB_PREFIX:-clab-agentic-netops-fabric-}
# Bootstrap tenants from lab/profiles/srlinux/config/leaf0*.cfg
L2VNI=${L2VNI:-100}
L3VNI=${L3VNI:-2000}
VXLAN_TUNNEL=${VXLAN_TUNNEL:-vxlan1}
# The ip-vrf loopbacks the leaves originate as Type-5 routes
IPVRF_PREFIXES=${IPVRF_PREFIXES:-"192.168.201.1 192.168.202.1"}
CONVERGE_TRIES=${CONVERGE_TRIES:-30}
CONVERGE_SLEEP=${CONVERGE_SLEEP:-10}

EVPN_RIB_IN="/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post"

die() { echo "[evpn-suite] FAIL: $*" >&2; exit 1; }
note() { echo "[evpn-suite] $*" >&2; }

tls_args() {
  printf '%s\n' --timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" \
    --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT"
}

gnmi_get() {
  local t=$1 path=$2
  "$GNMIC_BIN" --address "$t" $(tls_args) get --path "$path" 2>&1
}

# rpc_failed <output> — true when the request itself could not be asked. A
# transport failure must never be readable as proof of absence.
rpc_failed() {
  grep -qE 'rpc error|^Error:|connection refused|context deadline exceeded' <<<"$1"
}

# rib_entry_count <output> — number of EVPN RIB entries in a reply. Every entry
# in every EVPN route-type list carries exactly one route-distinguisher, which
# makes it a stable counter across the list shapes.
# VERIFY LIVE (config/NOTES.md): confirm the leaf spelling on 26.7.
rib_entry_count() {
  grep -o '"route-distinguisher"' <<<"$1" | wc -l | tr -d ' '
}

node_for_target() {
  local ip=${1%%:*}
  docker ps --format '{{.Names}}' | grep "^${CLAB_PREFIX}" | while read -r c; do
    local i
    i=$(docker inspect "$c" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null)
    if grep -qw "$ip" <<<"$i"; then echo "$c"; fi
  done | head -n1
}

# assert_received_routes <list> <label> — at least one route of this type must
# have ARRIVED from a peer on every leaf. Retries while the overlay converges.
assert_received_routes() {
  local list=$1 label=$2
  local rc=0 t out n i ok
  IFS=',' read -ra tgts <<<"$LEAVES"
  for t in "${tgts[@]}"; do
    ok=0
    for i in $(seq 1 "$CONVERGE_TRIES"); do
      out=$(gnmi_get "$t" "${EVPN_RIB_IN}/${list}")
      if rpc_failed "$out"; then
        # Not absence — an unaskable query. Keep retrying inside the window, but
        # report the transport error if it never clears.
        sleep "$CONVERGE_SLEEP"; continue
      fi
      n=$(rib_entry_count "$out")
      if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
        echo "[$t] assertion passed: ${label} — ${n} route(s) received from a peer (${list})"
        ok=1
        break
      fi
      sleep "$CONVERGE_SLEEP"
    done
    if (( ok == 0 )); then
      echo "[$t] ASSERTION FAILED: ${label} — no ${list} entry was received from a peer after $((CONVERGE_TRIES*CONVERGE_SLEEP))s" >&2
      echo "----- BEGIN [$t] OUTPUT -----" >&2
      echo "$out" | head -40 >&2
      echo "----- END [$t] OUTPUT -----" >&2
      rc=1
    fi
  done
  return $rc
}

EVPN_Type2() { assert_received_routes mac-ip-routes "EVPN Type-2 (MAC/IP) received"; }
EVPN_Type3() { assert_received_routes imet-routes "EVPN Type-3 (inclusive multicast) received"; }

# Type-5: the peer leaf's ip-vrf loopback must be present in the received EVPN
# RIB. Presence of *some* ip-prefix route is not enough — the peer's own prefix
# is what proves the ip-vrf is originating and the overlay is carrying it.
EVPN_Type5() {
  local rc=0 t out i ok pfx want
  IFS=',' read -ra tgts <<<"$LEAVES"
  for t in "${tgts[@]}"; do
    # the prefix this leaf must RECEIVE is the one it does not originate
    local node local_pfx=""
    node=$(node_for_target "$t")
    case "$node" in
      *leaf01) local_pfx=192.168.201.1 ;;
      *leaf02) local_pfx=192.168.202.1 ;;
    esac
    want=""
    for pfx in $IPVRF_PREFIXES; do
      [[ "$pfx" == "$local_pfx" ]] || want="$pfx"
    done
    [[ -n "$want" ]] || die "EVPN-Type5: cannot resolve the peer ip-vrf prefix for $t (node=$node)"
    ok=0
    for i in $(seq 1 "$CONVERGE_TRIES"); do
      out=$(gnmi_get "$t" "${EVPN_RIB_IN}/ip-prefix-routes")
      if ! rpc_failed "$out" && grep -q "$want" <<<"$out"; then
        echo "[$t] assertion passed: EVPN Type-5 (IP prefix) — peer prefix ${want} received"
        ok=1
        break
      fi
      sleep "$CONVERGE_SLEEP"
    done
    if (( ok == 0 )); then
      echo "[$t] ASSERTION FAILED: EVPN Type-5 — peer ip-vrf prefix ${want} never arrived in the received EVPN RIB" >&2
      echo "----- BEGIN [$t] OUTPUT -----" >&2
      echo "$out" | head -40 >&2
      echo "----- END [$t] OUTPUT -----" >&2
      rc=1
    fi
  done
  return $rc
}

# Remote VTEP: the one signal self-origination cannot fake. The multicast
# destination list under the L2VNI's vxlan-interface is non-empty only once the
# peer leaf's IMET has been received AND installed.
Remote_VTEP() {
  local rc=0 t out i ok n
  local path="/tunnel-interface[name=${VXLAN_TUNNEL}]/vxlan-interface[index=${L2VNI}]/bridge-table/multicast-destinations/destination"
  IFS=',' read -ra tgts <<<"$LEAVES"
  for t in "${tgts[@]}"; do
    ok=0
    for i in $(seq 1 "$CONVERGE_TRIES"); do
      out=$(gnmi_get "$t" "$path")
      if ! rpc_failed "$out"; then
        n=$(grep -o '"destination-index"\|"vtep-address"' <<<"$out" | wc -l | tr -d ' ')
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
          echo "[$t] assertion passed: ${n} remote VTEP destination(s) on ${VXLAN_TUNNEL}.${L2VNI} — peer IMET received and installed"
          ok=1
          break
        fi
      fi
      sleep "$CONVERGE_SLEEP"
    done
    if (( ok == 0 )); then
      echo "[$t] ASSERTION FAILED: 0 remote VTEPs on ${VXLAN_TUNNEL}.${L2VNI} — no EVPN route has been received from the peer leaf (self-originated routes do not prove exchange)" >&2
      echo "----- BEGIN [$t] OUTPUT -----" >&2
      echo "$out" | head -40 >&2
      echo "----- END [$t] OUTPUT -----" >&2
      rc=1
    fi
  done
  return $rc
}

# Overlay traffic: client01 -> client02 across the bootstrap mac-vrf. Both
# clients sit in 192.0.2.0/24 on an untagged bridged subinterface, so this ping
# can only succeed over the VXLAN overlay.
Overlay_Traffic() {
  local c1="${CLAB_PREFIX}client01" c2="${CLAB_PREFIX}client02" c out i
  for c in "$c1" "$c2"; do
    docker ps --format '{{.Names}}' | grep -qx "$c" \
      || { echo "[$c] ASSERTION FAILED: EVPN client container missing" >&2; return 1; }
  done
  # Client image is busybox: use sh, not bash.
  docker exec "$c1" sh -c 'ip -br addr show eth1 | grep -q "192.0.2.11/24" || ip addr add 192.0.2.11/24 dev eth1' || true
  docker exec "$c2" sh -c 'ip -br addr show eth1 | grep -q "192.0.2.21/24" || ip addr add 192.0.2.21/24 dev eth1' || true
  for i in $(seq 1 "$CONVERGE_TRIES"); do
    out=$(docker exec "$c1" ping -c3 -W2 192.0.2.21 2>&1) || true
    # Match with a leading space: a bare "0% packet loss" grep also matches
    # "100% packet loss" as a substring, which is how a total-loss run once
    # reported a false pass.
    if grep -q " 0% packet loss" <<<"$out"; then
      echo "[client01→client02] assertion passed: bridged vlan100 reachability across the overlay ($(grep ' 0% packet loss' <<<"$out"))"
      return 0
    fi
    sleep "$CONVERGE_SLEEP"
  done
  echo "[client01→client02] ASSERTION FAILED: no overlay reachability (last: $(grep -E 'packet loss|From' <<<"$out" | tail -1))" >&2
  return 1
}

main() {
  case "$1" in
    EVPN-Type2) EVPN_Type2 ;;
    EVPN-Type3) EVPN_Type3 ;;
    EVPN-Type5) EVPN_Type5 ;;
    Remote-VTEP) Remote_VTEP ;;
    Overlay-Traffic) Overlay_Traffic ;;
    *) echo "unknown test $1" >&2; exit 2 ;;
  esac
}

if [[ ${1:-} == "--run" ]]; then
  shift
  main "$@"
fi
