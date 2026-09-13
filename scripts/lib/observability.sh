#!/usr/bin/env bash
# Observability install helpers for Phase 7 (OTel Collector, gNMIc, Prometheus, Grafana)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}"

obs::install() {
  echo "[obs] applying OTel Collector, gNMIc, Prometheus, Grafana"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/otel-collector.yaml"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/gnmi/gnmic.yaml"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/prometheus.yaml"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/topology-configmap.yaml"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/rules/agentic-netops.rules.yaml" || true
  # Generate Grafana admin Secret with random credentials and apply Grafana
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/grafana-secret-generator-rbac.yaml"
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/grafana-secret-generator-job.yaml"
  kubectl --context "$CTX" -n monitoring wait --for=condition=Complete --timeout=30s job/grafana-admin-secret-generator || true
  kubectl --context "$CTX" apply -f "$ROOT_DIR/deploy/observability/grafana.yaml"
  # Wait for pods
  kubectl --context "$CTX" -n agentic-netops-system rollout status deploy/otel-collector --timeout=60s || true
  kubectl --context "$CTX" -n agentic-netops-system rollout status deploy/gnmic --timeout=60s || true
  kubectl --context "$CTX" -n monitoring rollout status deploy/prometheus --timeout=60s || true
  kubectl --context "$CTX" -n monitoring rollout status deploy/grafana --timeout=60s || true
  # Capture independent observation proof files
  local proofs="$ROOT_DIR/.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs"
  mkdir -p "$proofs"
  kubectl --context "$CTX" -n agentic-netops-system get deploy,po,svc -o wide | nl -ba > "$proofs/kubectl-get-observability-agentic-netops-system.txt"
  kubectl --context "$CTX" -n monitoring get deploy,po,svc,pvc -o wide | nl -ba > "$proofs/kubectl-get-observability-monitoring.txt"
}

# Validate no duplicate device time series: ensure only gNMIc collector deployment exists
obs::assert_single_device_collector() {
  local count
  count=$(kubectl --context "$CTX" -n agentic-netops-system get deploy -l app.kubernetes.io/name=gnmic --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${count:-0}" -ne 1 ]]; then
    echo "[obs] ERROR: expected exactly one gNMIc deployment, found $count" >&2
    return 1
  fi
  # Ensure the SDC SyncProfile's own subscribe is disabled, so device telemetry
  # has exactly one collector (gnmic) and no duplicate series. The profile is
  # named by deploy/sdc/seed/; resolve it rather than hard-coding one name.
  local sync_profile
  sync_profile=${SDC_SYNC_PROFILE:-$(kubectl --context "$CTX" -n sdc-system get config -o name 2>/dev/null \
    | sed 's|.*/||' | grep -- '-sync-profile$' | head -n1)}
  if [[ -z "$sync_profile" ]]; then
    echo "[obs] ERROR: no SDC SyncProfile config found in sdc-system; cannot prove device telemetry has a single collector" >&2
    return 1
  fi
  if ! kubectl --context "$CTX" -n sdc-system get config "$sync_profile" -o jsonpath='{.spec.data.subscribe}' 2>/dev/null | grep -q "^{}$"; then
    echo "[obs] ERROR: SDC SyncProfile ${sync_profile} subscribe not disabled" >&2
    return 1
  fi
  echo "[obs] single device collector and disabled SDC subscribe verified"
}

case "${1:-}" in
  install) shift; obs::install "$@" ;;
  assert-single) shift; obs::assert_single_device_collector "$@" ;;
  *) echo "usage: $0 {install|assert-single}" >&2; exit 2 ;;
esac
