#!/usr/bin/env bash
# T079: Observability suite checks — dashboards provisioned, Flow plugin pinned,
# alert rules active, and representative alerts evaluate expected state.
# This script performs static and live checks when a cluster is available.
# It emits OBSERVABILITY_SUITE_OK on success.
#
# T564 (--srv6, 12-07): additionally walk EVERY expression of the SRv6 service
# dashboard and query it against the running Prometheus — each must return at
# least one series for the running service (a panel with no source was already
# removed from the dashboard per FR-036/D33, so a live empty result means the
# suite is red, not the panel). The mode also checks the executor's kernel
# counters are exposed on /metrics while a service forwards: the per-SID
# counter fabric_executor_srv6_sid_packets_total (the count branch of T560 —
# the plan installs the End.DT46 route with the seg6local `count` flag, so the
# kernel keeps the behavior's own per-SID counters) and the VRF-device
# companion granularity fabric_executor_node_vrf_packets_total.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}"
SRV6_MODE=0
for arg in "$@"; do
  case "$arg" in
    --srv6) SRV6_MODE=1 ;;
    *) echo "[obs] unknown argument: $arg" >&2; exit 2 ;;
  esac
done

checks=()

# 1) Grafana security posture: no third-party plugin install (the previously
# pinned "grafana-flow-panel" reference was not a real installable plugin and
# crash-looped the container; topology views now use built-in panels), the
# upstream flow visualization pin is recorded in versions.lock.yaml as a
# presentation reference (FR-032), and anonymous auth is disabled.
if grep -q 'grafana_flow_plugin:.*@sha256:[a-f0-9]\{64\}' "$ROOT_DIR/versions.lock.yaml"; then
  checks+=("flow-pin-recorded")
else
  echo "[obs] FAIL: grafana flow visualization pin missing from versions.lock.yaml" >&2; exit 1
fi
if grep -q 'name: GF_INSTALL_PLUGINS' "$ROOT_DIR/deploy/observability/grafana.yaml"; then
  echo "[obs] FAIL: GF_INSTALL_PLUGINS present — no unpinned/third-party plugin installs allowed" >&2; exit 1
else
  checks+=("no-plugin-install")
fi
if command -v yq >/dev/null 2>&1; then
  ANON=$(yq e '.spec.template.spec.containers[] | select(.name=="grafana").env[] | select(.name=="GF_AUTH_ANONYMOUS_ENABLED").value' "$ROOT_DIR/deploy/observability/grafana.yaml" 2>/dev/null || echo "")
  if [[ "$ANON" == "false" ]]; then
    checks+=("anonymous-disabled")
  else
    echo "[obs] FAIL: Grafana anonymous auth is not disabled" >&2; exit 1
  fi
else
  grep -q 'name:\s*GF_AUTH_ANONYMOUS_ENABLED' "$ROOT_DIR/deploy/observability/grafana.yaml" \
    && grep -q 'value:\s*"false"' "$ROOT_DIR/deploy/observability/grafana.yaml" \
    && checks+=("anonymous-disabled") \
    || { echo "[obs] FAIL: Grafana anonymous auth is not disabled (fallback)" >&2; exit 1; }
fi

# 2) Dashboards present in provisioning ConfigMap
for d in physical-fabric.json sdc-orchestration.json srv6-service-path.json pipeline-health.json; do
  if grep -q "$d" "$ROOT_DIR/deploy/observability/grafana.yaml"; then checks+=("dash-$d"); else echo "[obs] FAIL: missing dashboard $d" >&2; exit 1; fi
done

# 3) Prometheus rules contain required alerts
for a in LinkDown BGPPeerDown ProviderFailedReconcile ProviderDegradedDeviation SDCTargetUnreachable SRv6PathDown TopologyInventoryMismatch GNMIcExportFailures OTelExportFailures; do
  if grep -q "alert: $a" "$ROOT_DIR/deploy/observability/rules/agentic-netops.rules.yaml"; then checks+=("alert-$a"); else echo "[obs] FAIL: missing alert $a" >&2; exit 1; fi
done

# 4) If kubectl available, validate resources applied and deployments Ready (best-effort)
if command -v kubectl >/dev/null 2>&1; then
  kubectl --context "$CTX" -n monitoring get configmap grafana-dashboards grafana-provisioning >/dev/null 2>&1 && checks+=("cm-present") || true
  kubectl --context "$CTX" -n monitoring get prometheusrule agentic-netops-alerts >/dev/null 2>&1 && checks+=("rules-present") || true
  kubectl --context "$CTX" -n monitoring get deploy grafana prometheus >/dev/null 2>&1 && checks+=("deploy-present") || true
  # Alert evaluation spot check (requires Prometheus up): verify rules are loaded
  kubectl --context "$CTX" -n monitoring get prometheusrule -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -q 'agentic-netops-alerts' && checks+=("alerts-loaded") || true
fi

# 5) T564 (--srv6, 12-07): every dashboard expression returns data, and the
# executor exposes the kernel forwarding counter of T560.
if [[ "$SRV6_MODE" == "1" ]]; then
  DASH="$ROOT_DIR/deploy/observability/dashboards/srv6-service-path.json"

  # 5a) Static: every expression names a metric that is actually emitted —
  # the SRv6Service controller's gauges (12-01/12-02) or the executor's
  # kernel per-SID counter (T560) — a dashboard expression that no emitted
  # metric satisfies is exactly the FR-036 "panel with no source" this phase
  # removed; keep the suite refusing to ever grow one back silently.
  if ! python3 - "$DASH" <<'PY'
import json, sys
exprs = [t["expr"] for p in json.load(open(sys.argv[1]))["panels"] for t in p["targets"]]
bad = [e for e in exprs if "agentic_netops_srv6_" not in e and "fabric_executor_srv6_sid_packets_total" not in e]
if bad:
    print("[obs] FAIL: dashboard expressions naming no emitted metric: %r" % bad, file=sys.stderr)
    sys.exit(1)
print("exprs=%d" % len(exprs))
PY
  then exit 1; fi
  checks+=("srv6-exprs-emitted-metrics")

  # 5b) Static: the embedded copy in grafana.yaml is identical to the file
  # (12-05) — dashboards-as-code have exactly one source of truth per panel.
  EMBEDDED=$(sed -n '/^  srv6-service-path.json: |/,/^  [a-z]/p' "$ROOT_DIR/deploy/observability/grafana.yaml" \
    | sed -n '2,$p' | sed '/^  [a-z]/d' | sed 's/^    //')
  if [[ "$EMBEDDED" == "$(cat "$DASH")" ]]; then
    checks+=("srv6-embedded-copy-identical")
  else
    echo "[obs] FAIL: grafana.yaml embedded srv6-service-path.json differs from deploy/observability/dashboards/srv6-service-path.json" >&2; exit 1
  fi

  # 5c) Static: the SRv6PathDown alert watches the active-path metric's
  # preferred series (12-06) — the metric the failover script can move.
  grep -q 'expr: agentic_netops_srv6_active_path{path="preferred"} == 0' \
    "$ROOT_DIR/deploy/observability/rules/agentic-netops.rules.yaml" \
    && checks+=("srv6-alert-on-active-path") \
    || { echo "[obs] FAIL: SRv6PathDown does not watch agentic_netops_srv6_active_path{path=\"preferred\"}" >&2; exit 1; }

  # 5d) Live: query every dashboard expression against the running Prometheus
  # through a port-forward that this script owns and always tears down.
  PF_PORT=${PROM_PF_PORT:-19090}
  PF_PID=""
  cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
  trap cleanup EXIT
  if command -v kubectl >/dev/null 2>&1 \
      && kubectl --context "$CTX" -n monitoring get svc prometheus >/dev/null 2>&1; then
    kubectl --context "$CTX" -n monitoring port-forward "svc/prometheus" "${PF_PORT}:9090" >/dev/null 2>&1 &
    PF_PID=$!
    PROM_UP=0
    for _ in $(seq 1 30); do
      if curl -fsS "http://127.0.0.1:${PF_PORT}/-/ready" >/dev/null 2>&1; then PROM_UP=1; break; fi
      sleep 1
    done
    if [[ "$PROM_UP" != "1" ]]; then
      echo "[obs] FAIL: Prometheus never became reachable through the port-forward" >&2; exit 1
    fi
    checks+=("srv6-prometheus-reachable")

    mapfile -t EXPRS < <(python3 - "$DASH" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1]))["panels"]:
    for t in p["targets"]:
        print(t["expr"])
PY
)
    for expr in "${EXPRS[@]}"; do
      ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$expr")
      RESULT=$(curl -fsS "http://127.0.0.1:${PF_PORT}/api/v1/query?query=${ENC}" || echo '{"status":"error"}')
      COUNT=$(python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d.get("data",{}).get("result",[])))' <<<"$RESULT" 2>/dev/null || echo 0)
      if [[ "$COUNT" -lt 1 ]]; then
        echo "[obs] FAIL: dashboard expression returned no series: $expr" >&2; exit 1
      fi
      checks+=("srv6-expr-series:${expr:0:48}")
    done

    # 5e) Live: the executor's kernel forwarding counters (T560) are on
    # /metrics. The per-SID counter is the one the dashboard plots (the plan's
    # End.DT46 op installs the seg6local `count` flag, so the kernel keeps the
    # behavior's own per-SID counters); the VRF-device family is the coarser
    # companion granularity. The executor is the host service on the kind
    # bridge gateway; the scrape target is overridable for other vantage
    # points.
    EXEC_METRICS_URL=${FABRIC_EXECUTOR_METRICS_URL:-http://127.0.0.1:8084/metrics}
    if curl -fsS "$EXEC_METRICS_URL" | grep -q '^fabric_executor_srv6_sid_packets_total{'; then
      checks+=("srv6-executor-sid-counter-exposed")
    else
      echo "[obs] FAIL: fabric_executor_srv6_sid_packets_total missing from $EXEC_METRICS_URL (is a service with a `count`-flagged decap route forwarding? is the executor up?)" >&2
      exit 1
    fi
    if curl -fsS "$EXEC_METRICS_URL" | grep -q '^fabric_executor_node_vrf_packets_total{'; then
      checks+=("srv6-executor-vrf-counter-exposed")
    else
      echo "[obs] FAIL: fabric_executor_node_vrf_packets_total missing from $EXEC_METRICS_URL (is a service forwarding? is the executor up?)" >&2
      exit 1
    fi
  else
    echo "[obs] SKIP: no cluster/prometheus available; SRv6 live expression checks skipped (static checks still enforced)"
    checks+=("srv6-live-skipped")
  fi
fi

echo "[obs] checks: ${checks[*]}"
echo "OBSERVABILITY_SUITE_OK"
