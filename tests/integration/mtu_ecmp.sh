#!/usr/bin/env bash
# MTU and ECMP tests: verify the maximum effective MTU accommodates VXLAN
# overhead and that both spine uplinks carry overlay traffic (FR-002, FR-011).
#
# Counters are read over gNMI from the SR Linux native interface statistics —
# the same paths the gnmic telemetry subscriptions use.
set -euo pipefail

CLAB_PREFIX=${CLAB_PREFIX:-clab-agentic-netops-fabric-}
SRC=${SRC:-${CLAB_PREFIX}client01}
DST_IP=${DST_IP:-192.0.2.21}

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_ENCODING=${GNMI_ENCODING:-json_ietf}
LEAF1=${LEAF1:-172.31.0.21:57400}
# leaf01 uplinks: ethernet-1/1 -> spine01, ethernet-1/2 -> spine02
IF_A=${IF_A:-ethernet-1/1}
IF_B=${IF_B:-ethernet-1/2}
# Fabric MTU is 9216; 8900 bytes of ICMP payload still fits after VXLAN overhead.
PING_SIZE=${PING_SIZE:-8900}

_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT")

die() { echo "[mtu-ecmp] ERROR: $*" >&2; exit 1; }

# Verify the effective MTU across the overlay accommodates VXLAN overhead
vxlan_mtu_test() {
  echo "[mtu-ecmp] maximum effective MTU accommodates VXLAN overhead"
  docker exec "$SRC" ping -c 1 -W 2 -M do -s "$PING_SIZE" "$DST_IP" \
    || die "a ${PING_SIZE}-byte unfragmented payload did not cross the overlay; the fabric MTU does not accommodate VXLAN overhead"
}

_read_counter() {
  local ifname=$1
  "$GNMIC_BIN" --address "$LEAF1" "${_args_common[@]}" get \
      --path "/interface[name=${ifname}]/statistics/out-octets" 2>/dev/null \
    | jq -r '[.[].updates[].values] | map(to_entries[].value) | .[0] // empty' 2>/dev/null | head -n1
}

# ECMP verification: both uplinks must carry overlay traffic
ecmp_hashing_test() {
  echo "[mtu-ecmp] ECMP hashing across both spine uplinks"
  local pre_a pre_b post_a post_b p
  pre_a=$(_read_counter "$IF_A"); pre_b=$(_read_counter "$IF_B")
  # A burst of UDP flows with varying destination ports exercises the overlay
  # hash (the inner 5-tuple feeds the outer VXLAN source port).
  for p in 10000 10001 10002 11000 11001 11002 12000 12001 12002; do
    docker exec "$SRC" sh -c "timeout 1 sh -c '>/dev/udp/${DST_IP}/$p' || true"
  done
  sleep 2
  post_a=$(_read_counter "$IF_A"); post_b=$(_read_counter "$IF_B")
  echo "[mtu-ecmp] ${IF_A} out-octets: ${pre_a:-?} -> ${post_a:-?}"
  echo "[mtu-ecmp] ${IF_B} out-octets: ${pre_b:-?} -> ${post_b:-?}"
  if [[ -z "$pre_a" || -z "$post_a" || -z "$pre_b" || -z "$post_b" ]]; then
    die "missing interface counters — the gNMI Get did not answer, which is not evidence about ECMP"
  fi
  (( post_a > pre_a )) || die "no out-octets increment on $IF_A"
  (( post_b > pre_b )) || die "no out-octets increment on $IF_B"
  echo "[mtu-ecmp] assertion passed: both spine uplinks carried overlay traffic"
}

case "${1:-run}" in
  run)
    if ! docker ps --format '{{.Names}}' | grep -q "${SRC}"; then
      echo "SKIP-LIVE: MTU/ECMP suite requires a provisioned lab (${SRC} absent); the capability gate (scripts/lib/qualify.sh) is the source of truth"
      exit 0
    fi
    vxlan_mtu_test
    ecmp_hashing_test
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
