#!/usr/bin/env bash
# T047a [US3] MTU and ECMP tests: verify maximum effective MTU accommodates VXLAN overhead and ECMP hashing
set -euo pipefail

CLAB_PREFIX=${CLAB_PREFIX:-clab-ainetops-fabric-}
SRC=${SRC:-${CLAB_PREFIX}client01}
DST_IP=${DST_IP:-192.0.2.21}

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}
LEAF1=${LEAF1:-172.31.0.21:8080}

_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --tls --skip-verify --encoding "$GNMI_ENCODING" --cacert "$GNMI_CACERT" --cert "$GNMI_CERT" --key "$GNMI_KEY")

# Verify effective MTU across the overlay accommodates VXLAN overhead
vxlan_mtu_test() {
  echo "[mtu-ecmp] maximum effective MTU accommodates VXLAN overhead"
  # attempt a near-jumbo payload; 8900 bytes payload should pass with 9216 underlay MTU
  docker exec "$SRC" ping -c 1 -W 2 -M do -s 8900 "$DST_IP"
}

_read_counter() {
  local ifname=$1; shift
  "$GNMIC_BIN" --address "$LEAF1" "${_args_common[@]}" get --path \
    "/openconfig-interfaces:interfaces/interface[name=${ifname}]/state/counters/out-octets" -o json \
    | jq -r '..|objects|select(has("out-octets"))|."out-octets"' | head -n1
}

# ECMP hashing verification (distribution across spines)
ecmp_hashing_test() {
  echo "[mtu-ecmp] ECMP hashing where qualified"
  local IF_A=${IF_A:-Ethernet1} # uplink to spine01
  local IF_B=${IF_B:-Ethernet2} # uplink to spine02
  local pre_a pre_b post_a post_b
  pre_a=$(_read_counter "$IF_A"); pre_b=$(_read_counter "$IF_B")
  # Send a burst of UDP flows with varying src ports to exercise ECMP hashing (overlay)
  for p in 10000 10001 10002 11000 11001 11002 12000 12001 12002; do
    docker exec "$SRC" bash -lc "timeout 0.2 bash -c '>/dev/udp/${DST_IP}/$p' || true"
  done
  sleep 1
  post_a=$(_read_counter "$IF_A"); post_b=$(_read_counter "$IF_B")
  echo "[mtu-ecmp] ${IF_A} out-octets: $pre_a -> $post_a"
  echo "[mtu-ecmp] ${IF_B} out-octets: $pre_b -> $post_b"
  # Assert both interfaces saw traffic increments
  if [[ -z "$pre_a" || -z "$post_a" || -z "$pre_b" || -z "$post_b" ]]; then
    echo "[mtu-ecmp] ERROR: missing interface counters" >&2; exit 1
  fi
  if (( post_a <= pre_a )); then echo "[mtu-ecmp] ERROR: no increment on $IF_A" >&2; exit 1; fi
  if (( post_b <= pre_b )); then echo "[mtu-ecmp] ERROR: no increment on $IF_B" >&2; exit 1; fi
}

case "${1:-run}" in
  run)
    vxlan_mtu_test
    ecmp_hashing_test
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
