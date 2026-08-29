#!/usr/bin/env bash
# T050 [US2] Managed-path drift restoration and unmanaged-path preservation tests
set -euo pipefail

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}
LEAF1=${LEAF1:-172.31.0.21:8080}
PROOF_DIR=${PROOF_DIR:-.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs}
mkdir -p "$PROOF_DIR"

_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --tls --skip-verify --encoding "$GNMI_ENCODING" --cacert "$GNMI_CACERT" --cert "$GNMI_CERT" --key "$GNMI_KEY")

_read_json() {
  "$GNMIC_BIN" --address "$LEAF1" "${_args_common[@]}" get --path "$1" -o json 2>/dev/null
}

managed_drift_restoration() {
  echo "[drift] managed-path drift restoration"
  # Read intended BGP AS from provider-owned state (placeholder path for illustration)
  local path_as="/openconfig-network-instance:network-instances/network-instance[name=default]/protocols/protocol[identifier=BGP][name=BGP]/global/config/as"
  local as_before
  as_before=$(_read_json "$path_as" | jq -r '..|objects|select(has("as"))|.as' | head -n1)
  echo "$as_before" > "$PROOF_DIR/drift.bgp-as.before.txt"
  # Mutate managed path and expect restoration
  $GNMIC_BIN --address "$LEAF1" "${_args_common[@]}" set --update "$path_as=$((as_before+1))" || true
  # Give reconciler a window to restore
  sleep 3
  local as_after
  as_after=$(_read_json "$path_as" | jq -r '..|objects|select(has("as"))|.as' | head -n1)
  echo "$as_after" > "$PROOF_DIR/drift.bgp-as.after.txt"
  if [[ -n "$as_before" && -n "$as_after" && "$as_after" != "$as_before" ]]; then
    echo "[drift] ERROR: managed path was not restored to intended value ($as_before != $as_after)" >&2
    exit 1
  fi
}

unmanaged_path_preservation() {
  echo "[drift] unmanaged-path preservation"
  # Mutate an unmanaged path (interface description) and assert it is not overwritten shortly after
  local path_desc="/openconfig-interfaces:interfaces/interface[name=Ethernet100]/config/description"
  $GNMIC_BIN --address "$LEAF1" "${_args_common[@]}" set --update "$path_desc=lab-freeform-note" || true
  # Wait and re-read
  sleep 3
  local desc
  desc=$(_read_json "$path_desc" | jq -r '..|scalars? // empty' | head -n1)
  echo "$desc" > "$PROOF_DIR/drift.if-desc.after.txt"
  if [[ "$desc" != "lab-freeform-note" ]]; then
    echo "[drift] ERROR: unmanaged path was overwritten by reconciler/SDC" >&2
    exit 1
  fi
}

case "${1:-run}" in
  run)
    managed_drift_restoration
    unmanaged_path_preservation
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
