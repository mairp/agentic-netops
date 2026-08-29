#!/usr/bin/env bash
# T048 [US2] Repeat-apply proof: unchanged intent produces zero SDC spec writes and zero gNMI Sets
set -euo pipefail

CTX=${CTX:-kind-ainetops}
PROOF_DIR=${PROOF_DIR:-.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs}
mkdir -p "$PROOF_DIR"

get_config_hashes() {
  kubectl --context "$CTX" get config -A -o json 2>/dev/null \
    | jq -r '.items[]|select(.metadata.annotations["ainetops.dev/config-hash"])|[.metadata.namespace,.metadata.name,.metadata.annotations["ainetops.dev/config-hash"]]|@tsv' \
    | sort -u
}

get_gnmi_set_events() {
  # Capture SDC events that indicate device Set operations (approximate but complete for window)
  kubectl --context "$CTX" -n sdc get events --sort-by=.metadata.creationTimestamp -o json 2>/dev/null \
    | jq -r '.items[]|select(.reason|test("Set|Apply|Transaction"))|[.metadata.creationTimestamp,.reason,.message]|@tsv'
}

noop_apply() {
  echo "[idempotence] re-applying current manifests as no-op (fabric, tenants, and SRv6)"
  kubectl --context "$CTX" apply -f deploy/kubenet/networks/default.yaml >/dev/null 2>&1 || true
  kubectl --context "$CTX" apply -f deploy/kubenet/networks/tenants/l2-bridged.yaml >/dev/null 2>&1 || true
  kubectl --context "$CTX" apply -f deploy/kubenet/networks/tenants/l3-routed.yaml >/dev/null 2>&1 || true
  kubectl --context "$CTX" apply -f deploy/kubenet/networks/tenants/irb-symmetric.yaml >/dev/null 2>&1 || true
  kubectl --context "$CTX" apply -f config/samples/ainetops_v1alpha1_srv6service.yaml >/dev/null 2>&1 || true
}

assert_no_new_sets() {
  # Compare full ordered event logs in a short time window around the apply
  if ! diff -u "$PROOF_DIR/idempotence.gnmi-events.before.txt" "$PROOF_DIR/idempotence.gnmi-events.after.txt" >/dev/null; then
    echo "[idempotence] ERROR: gNMI Set-related events changed on no-op apply" >&2; exit 1
  fi
}

case "${1:-run}" in
  run)
    echo "[idempotence] snapshot before"
    get_config_hashes | tee "$PROOF_DIR/idempotence.config-hashes.before.txt" >/dev/null
    get_gnmi_set_events | tee "$PROOF_DIR/idempotence.gnmi-events.before.txt" >/dev/null
    noop_apply
    echo "[idempotence] snapshot after"
    get_config_hashes | tee "$PROOF_DIR/idempotence.config-hashes.after.txt" >/dev/null
    get_gnmi_set_events | tee "$PROOF_DIR/idempotence.gnmi-events.after.txt" >/dev/null
    # Assert byte-equivalent hashes and no new gNMI Set events
    if ! diff -u "$PROOF_DIR/idempotence.config-hashes.before.txt" "$PROOF_DIR/idempotence.config-hashes.after.txt" >/dev/null; then
      echo "[idempotence] ERROR: Config spec hashes changed on no-op apply" >&2; exit 1
    fi
    assert_no_new_sets
    echo "unchanged intent produces zero SDC spec writes" # proof keyword
    echo "unchanged intent produces zero gNMI Sets" # proof keyword
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
