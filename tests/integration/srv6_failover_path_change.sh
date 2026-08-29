#!/usr/bin/env bash
# T047c [US5] Failover and operator-directed path-change tests
set -euo pipefail

TOPO=${TOPO:-lab/topology.clab.yml}
SERVICE_NS=${SERVICE_NS:-default}
SERVICE_NAME=${SERVICE_NAME:-example-srv6}
LEAF_HEADEND=${LEAF_HEADEND:-172.31.0.21:8080}
GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}
_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --tls --skip-verify --encoding "$GNMI_ENCODING" --cacert "$GNMI_CACERT" --cert "$GNMI_CERT" --key "$GNMI_KEY")
PROOF_DIR=${PROOF_DIR:-.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs}
mkdir -p "$PROOF_DIR"

fail_link() {
  echo "[srv6-failover] force primary failure"
  containerlab -t "$TOPO" link down spine01:eth1 leaf01:eth1 || true
}

assert_alert() {
  echo "[srv6-failover] assert the corresponding alert"
  # Require SRv6PathDown alert to exist
  if ! kubectl -n monitoring get alerts --no-headers 2>/dev/null | grep -q "SRv6PathDown"; then
    echo "[srv6-failover] ERROR: SRv6PathDown alert not observed" >&2
    exit 1
  fi
}

policy_state() {
  "$GNMIC_BIN" --address "$LEAF_HEADEND" "${_args_common[@]}" get --path "/sonic-srv6:sonic-srv6/POLICY" -o json
}

operator_path_change() {
  echo "[srv6-failover] update spec.pathPolicy.selectedPath=alternate"
  kubectl -n "$SERVICE_NS" patch srv6service "$SERVICE_NAME" --type merge -p '{"spec":{"pathPolicy":{"selectedPath":"alternate"}}}'
  # Assert the spec reflects the operator directive
  local sel
  sel=$(kubectl -n "$SERVICE_NS" get srv6service "$SERVICE_NAME" -o jsonpath='{.spec.pathPolicy.selectedPath}')
  if [[ "$sel" != "alternate" ]]; then
    echo "[srv6-failover] ERROR: selectedPath not set to alternate in spec (got '$sel')" >&2
    exit 1
  fi
}

verify_recovery() {
  echo "[srv6-failover] verify recovery and resulting path without telemetry-driven mutation"
  # Capture policy state before and after to verify alternate path selection took effect
  local before after
  before=$(policy_state | tee "$PROOF_DIR/srv6_policy_state.before.json" >/dev/null)
  # give controller time to react
  sleep 3
  after=$(policy_state | tee "$PROOF_DIR/srv6_policy_state.after.json" >/dev/null)
  # Assert the active policy now references the alternate path (name or sid-list containing 'alternate')
  if ! jq -e '..|scalars|select(type=="string")|contains("alternate")' <<<"$after" >/dev/null; then
    echo "[srv6-failover] ERROR: SRv6 POLICY does not reflect alternate path after operator change" >&2
    exit 1
  fi
  # And previously it did not (best-effort)
  if jq -e '..|scalars|select(type=="string")|contains("alternate")' <<<"$before" >/dev/null; then
    echo "[srv6-failover] WARN: POLICY already contained 'alternate' before change (environment may already be on alternate)" >&2
  fi
}

repair_link() {
  echo "[srv6-failover] restore primary link"
  containerlab -t "$TOPO" link up spine01:eth1 leaf01:eth1 || true
}

case "${1:-run}" in
  run)
    fail_link
    assert_alert
    operator_path_change
    verify_recovery
    repair_link
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
