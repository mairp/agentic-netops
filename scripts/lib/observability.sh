#!/usr/bin/env bash
# Observability install helpers for Phase 7 (OTel Collector, gNMIc, Prometheus, Grafana)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CTX="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"

obs::install() {
  echo "[obs] applying OTel Collector, gNMIc, Prometheus, Grafana"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/otel-collector.yaml"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/gnmi/gnmic.yaml"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/prometheus.yaml"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/topology-configmap.yaml"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/rules/ainetops.rules.yaml" || true
  # Generate Grafana admin Secret with random credentials and apply Grafana
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/grafana-secret-generator-rbac.yaml"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/grafana-secret-generator-job.yaml"
  kubectl --context "$CTX" -n monitoring wait --for=condition=Complete --timeout=30s job/grafana-admin-secret-generator || true
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/grafana.yaml"
  # Wait for pods
  kubectl --context "$CTX" -n ainetops-system rollout status deploy/otel-collector --timeout=60s || true
  kubectl --context "$CTX" -n ainetops-system rollout status deploy/gnmic --timeout=60s || true
  kubectl --context "$CTX" -n monitoring rollout status deploy/prometheus --timeout=60s || true
  kubectl --context "$CTX" -n monitoring rollout status deploy/grafana --timeout=60s || true
  # Capture independent observation proof files
  local proofs="$ROOT_DIR/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs"
  mkdir -p "$proofs"
  kubectl --context "$CTX" -n ainetops-system get deploy,po,svc -o wide | nl -ba > "$proofs/kubectl-get-observability-ainetops-system.txt"
  kubectl --context "$CTX" -n monitoring get deploy,po,svc,pvc -o wide | nl -ba > "$proofs/kubectl-get-observability-monitoring.txt"
}

# Validate no duplicate device time series: ensure only gNMIc collector deployment exists
obs::assert_single_device_collector() {
  local count
  count=$(kubectl --context "$CTX" -n ainetops-system get deploy -l app.kubernetes.io/name=gnmic --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${count:-0}" -ne 1 ]]; then
    echo "[obs] ERROR: expected exactly one gNMIc deployment, found $count" >&2
    return 1
  fi
  # Ensure SDC SyncProfile subscribe is disabled to avoid overlap
  if ! kubectl --context "$CTX" -n sdc-system get config sonic-sync-profile -o jsonpath='{.spec.data.subscribe}' 2>/dev/null | grep -q "^{}$"; then
    echo "[obs] ERROR: SDC SyncProfile subscribe not disabled" >&2
    return 1
  fi
  echo "[obs] single device collector and disabled SDC subscribe verified"
}

case "${1:-}" in
  install) shift; obs::install "$@" ;;
  assert-single) shift; obs::assert_single_device_collector "$@" ;;
  *) echo "usage: $0 {install|assert-single}" >&2; exit 2 ;;
esac
