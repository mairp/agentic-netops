#!/usr/bin/env bash
# T047c [US5] Failover and operator-directed path-change tests
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOPO=${TOPO:-$ROOT_DIR/lab/topology.clab.yml}
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
_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT" --tls-cert "$GNMI_CERT" --tls-key "$GNMI_KEY")
PROOF_DIR=${PROOF_DIR:-.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs}
mkdir -p "$PROOF_DIR"

# containerlab 0.7x has no `link down/up` subcommand; we drive the interface via
# docker exec on the spine01 container (clab-ainetops-fabric-spine01).
FAIL_IF=${FAIL_IF:-eth1}
SPINE01_CONTAINER=${SPINE01_CONTAINER:-clab-ainetops-fabric-spine01}

fail_link() {
  echo "[srv6-failover] force primary failure (down ${FAIL_IF} on ${SPINE01_CONTAINER})"
  docker exec "${SPINE01_CONTAINER}" ip link set "${FAIL_IF}" down || { echo "[srv6-failover] SKIP: cannot reach ${SPINE01_CONTAINER}" >&2; return 0; }
}

assert_alert() {
  echo "[srv6-failover] assert the corresponding alert (SRv6PathDown active in Prometheus)"
  # Alerts are Prometheus state, not a Kubernetes resource: query the Prometheus
  # HTTP API through a port-forward and look for an active SRv6PathDown alert.
  local pf_port=19095 pf_pid
  kubectl --context "${CTX:-kind-ainetops}" -n monitoring port-forward svc/prometheus "${pf_port}":9090 >/dev/null 2>&1 &
  pf_pid=$!
  # Wait for the port-forward to come up
  local i
  for i in $(seq 1 20); do
    if curl -s "http://127.0.0.1:${pf_port}/-/healthy" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  # Poll for the active alert (it fires within the evaluation interval)
  local seen=""
  for i in $(seq 1 30); do
    seen=$(curl -s "http://127.0.0.1:${pf_port}/api/v1/alerts" 2>/dev/null \
      | jq -r '.data.alerts[]? | select(.labels.alertname=="SRv6PathDown") | .labels.instance' 2>/dev/null || true)
    [[ -n "$seen" ]] && break
    sleep 4
  done
  kill "${pf_pid}" >/dev/null 2>&1 || true
  if [[ -z "$seen" ]]; then
    echo "[srv6-failover] ERROR: SRv6PathDown alert not observed in Prometheus" >&2
    exit 1
  fi
  echo "[srv6-failover] SRv6PathDown active for: $(echo "$seen" | tr '\n' ' ')" | tee "$PROOF_DIR/srv6-pathdown-alert.txt"
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
  echo "[srv6-failover] restore primary link (up ${FAIL_IF} on ${SPINE01_CONTAINER})"
  docker exec "${SPINE01_CONTAINER}" ip link set "${FAIL_IF}" up || { echo "[srv6-failover] WARN: cannot restore ${FAIL_IF} on ${SPINE01_CONTAINER}" >&2; return 0; }
}

case "${1:-run}" in
  run)
    # Clean skip when no provisioned lab/cluster exists (absent-state runs, post-teardown).
    if ! docker ps --format '{{.Names}}' | grep -q "${SPINE01_CONTAINER}" \
      || ! kubectl --context kind-ainetops get nodes --request-timeout=5s >/dev/null 2>&1; then
      echo "SKIP-LIVE: SRv6 failover/path-change suite requires a provisioned lab and Kind cluster (${SPINE01_CONTAINER} or cluster absent); capability gate (scripts/lib/qualify.sh) is the source of truth"
      exit 0
    fi
    fail_link
    assert_alert
    operator_path_change
    verify_recovery
    repair_link
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
