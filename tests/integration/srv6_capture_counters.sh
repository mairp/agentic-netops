#!/usr/bin/env bash
# T047b [US5] SRv6 capture and counter tests between dedicated clients
# Capture outer IPv6/SRH with ordered SIDs, verify egress decapsulation into the intended VRF, and assert MySID counter increments
set -euo pipefail

PROOF_DIR=${PROOF_DIR:-.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs}
mkdir -p "$PROOF_DIR"

SRC=${SRC:-clab-ainetops-fabric-srv6-client01}
DST=${DST:-clab-ainetops-fabric-srv6-client02}
# Precondition: skip gracefully if clients are absent (standard SKIP-LIVE marker,
# matching evpn_traffic.sh / failure_recovery_invalid_yang.sh / srv6_failover_path_change.sh)
if ! docker ps --format '{{.Names}}' | grep -q "$SRC"; then echo "SKIP-LIVE: SRv6 capture/counter suite requires a provisioned lab (${SRC} not present); capability gate (scripts/lib/qualify.sh) is the source of truth"; exit 0; fi
if ! docker ps --format '{{.Names}}' | grep -q "$DST"; then echo "SKIP-LIVE: SRv6 capture/counter suite requires a provisioned lab (${DST} not present); capability gate (scripts/lib/qualify.sh) is the source of truth"; exit 0; fi
SRC_IP6=${SRC_IP6:-2001:db8:3::31}
DST_IP6=${DST_IP6:-2001:db8:4::41}
LEAF_SRC=${LEAF_SRC:-172.31.0.21:8080}
LEAF_DST=${LEAF_DST:-172.31.0.22:8080}
VRF_NAME=${VRF_NAME:-vrf-a}

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}

_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT" --tls-cert "$GNMI_CERT" --tls-key "$GNMI_KEY")

_capture_file_container=/tmp/srv6.pcap
_capture_file_host="$PROOF_DIR/srv6_outer_srh.pcap"
_capture_text_host="$PROOF_DIR/srv6_outer_srh.txt"

start_capture() {
  echo "[srv6-capture] capture outer IPv6/SRH with ordered SIDs"
  docker exec -d "$SRC" bash -lc "tcpdump -i eth1 -w $_capture_file_container ip6 and dst ${DST_IP6} and srh"
}

stop_capture() {
  echo "[srv6-capture] stopping capture and copying proof"
  docker exec "$SRC" bash -lc "pkill -f 'tcpdump -i eth1' || true"
  docker cp "$SRC:$_capture_file_container" "$_capture_file_host" || true
  if [[ -f "$_capture_file_host" ]]; then
    # textual summary for proof and inspection
    tcpdump -nnvv -r "$_capture_file_host" 2>/dev/null | tee "$_capture_text_host" >/dev/null || true
    sha256sum "$_capture_file_host" | tee "$PROOF_DIR/srv6_outer_srh.pcap.sha256"
  fi
}

send_srv6_traffic() {
  echo "[srv6-capture] generating SRv6 traffic"
  docker exec "$SRC" bash -lc "ping -6 -c 5 -W 1 ${DST_IP6} || true"
}

mysid_counter() {
  local when=$1; shift
  "$GNMIC_BIN" --address "$LEAF_DST" "${_args_common[@]}" get --path \
    "/sonic-srv6:sonic-srv6/SRV6_COUNTERS" -o json \
    | tee "$PROOF_DIR/mysid_counters.${when}.json" >/dev/null
}

assert_mysid_increment() {
  echo "[srv6-capture] assert MySID counter increments"
  local b a
  b=$(jq -r '..|objects|select(has("mysid"))|.mysid|numbers' "$PROOF_DIR/mysid_counters.before.json" | paste -sd+ - | bc || echo 0)
  a=$(jq -r '..|objects|select(has("mysid"))|.mysid|numbers' "$PROOF_DIR/mysid_counters.after.json" | paste -sd+ - | bc || echo 0)
  echo "[srv6-capture] MySID counters sum: $b -> $a"
  if (( a <= b )); then echo "[srv6-capture] ERROR: MySID counters did not increase" >&2; exit 1; fi
}

expected_sid_list() {
  # Obtain ordered SIDs from the active SID_LIST on the headend leaf
  "$GNMIC_BIN" --address "$LEAF_SRC" "${_args_common[@]}" get --path "/sonic-srv6:sonic-srv6/SID_LIST" -o json \
    | tee "$PROOF_DIR/sid_list.leaf-src.json" >/dev/null \
    | jq -r '..|objects|select(has("sids"))|.sids[]' || true
}

assert_ordered_sids_in_pcap() {
  echo "[srv6-capture] assert ordered SIDs present in captured SRH"
  if [[ ! -s "$_capture_text_host" ]]; then
    echo "[srv6-capture] ERROR: capture text not found at $_capture_text_host" >&2; exit 1
  fi
  mapfile -t sids < <(expected_sid_list)
  if (( ${#sids[@]} < 1 )); then
    echo "[srv6-capture] ERROR: could not discover expected SID list from headend; cannot verify ordering" >&2
    exit 1
  fi
  local prev_line=-1
  for sid in "${sids[@]}"; do
    local ln
    ln=$(grep -n -m1 -F "$sid" "$_capture_text_host" | cut -d: -f1 || true)
    if [[ -z "${ln:-}" ]]; then
      echo "[srv6-capture] ERROR: expected SID $sid not found in capture" >&2; exit 1
    fi
    if (( prev_line != -1 && ln < prev_line )); then
      echo "[srv6-capture] ERROR: SRH SID order invalid: $sid appears before previous SID" >&2; exit 1
    fi
    prev_line=$ln
  done
  echo "ordered SIDs verified" | tee "$PROOF_DIR/srv6_ordered_sids.ok" >/dev/null
}

assert_decap_vrf_on_leaf() {
  echo "[srv6-capture] verify egress decapsulation into the intended VRF"
  # Assert End.DT46 behavior on destination leaf maps to VRF_NAME
  "$GNMIC_BIN" --address "$LEAF_DST" "${_args_common[@]}" get --path "/sonic-srv6:sonic-srv6/BEHAVIORS" -o json \
    | tee "$PROOF_DIR/behaviors.leaf-dst.json" >/dev/null
  local vrf
  vrf=$(jq -r '..|objects|select((.behavior=="End.DT46" or .action=="End.DT46") and (has("vrf") or has("vrf-name")))|(.vrf // ."vrf-name")' "$PROOF_DIR/behaviors.leaf-dst.json" | head -n1)
  if [[ -z "${vrf:-}" ]]; then
    echo "[srv6-capture] ERROR: could not find End.DT46 VRF behavior on destination leaf" >&2; exit 1
  fi
  if [[ "$vrf" != "$VRF_NAME" ]]; then
    echo "[srv6-capture] ERROR: decap VRF mismatch: expected $VRF_NAME got $vrf" >&2; exit 1
  fi
}

case "${1:-run}" in
  run)
    mysid_counter before
    start_capture
    send_srv6_traffic
    stop_capture
    mysid_counter after
    assert_mysid_increment
    assert_ordered_sids_in_pcap
    assert_decap_vrf_on_leaf
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
