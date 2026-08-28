#!/usr/bin/env bash
# run-loop.sh — resume the wiggum proposer/critic loop for this feature.
#   ./scripts/run-loop.sh          resume with live timeline + telemetry
#   ./scripts/run-loop.sh --quiet  resume without the live view
#   ./scripts/run-loop.sh --stop   stop a running loop cleanly
set -euo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEATURE="001-ainetops-sonic-evpn-fabric"
SPEC="$WORKDIR/specs/$FEATURE/tasks.md"
ORCH="${ORCH:-/root/wiggum/orchestrator.sh}"

if [[ "${1:-}" == "--stop" ]]; then
  touch "$WORKDIR/.wiggum/stop.flag"
  echo "stop flag set — the loop halts at its next checkpoint (exit 6 is a clean stop)"
  exit 0
fi

[[ -x "$ORCH" ]] || { echo "orchestrator not found: $ORCH" >&2; exit 1; }
[[ -f "$SPEC" ]]  || { echo "spec not found: $SPEC" >&2; exit 1; }

# A leftover stop flag makes the loop exit 6 immediately.
rm -f "$WORKDIR/.wiggum/stop.flag"

LIVE=(--live --debug)
[[ "${1:-}" == "--quiet" ]] && LIVE=(--no-live)

LOKI="${LOKI_URL:-http://127.0.0.1:3100}"
OTLP="${OTEL_URL:-http://127.0.0.1:4318}"
GRAFANA="${GRAFANA_URL:-http://127.0.0.1:3000}"
TASK="$(basename "$WORKDIR")"

# A reachable endpoint may answer 405/503 and still be healthy for our purposes
# (Loki /ready reports 503 while serving queries; OTLP rejects GET). Treat any
# HTTP response as reachable, and only a connection failure as down.
probe() {  # name url path
  local code
  code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$2$3" 2>/dev/null || echo 000)"
  if [[ "$code" != "000" ]]; then
    printf '  \033[32m✓\033[0m %-8s %-24s HTTP %s\n' "$1" "$2" "$code"
  else
    printf '  \033[33m✗\033[0m %-8s %-24s unreachable (events still land in run.log)\n' "$1" "$2"
  fi
}

echo
echo "Observability"
probe Loki     "$LOKI"    /loki/api/v1/labels
probe OTLP     "$OTLP"    /v1/metrics
probe Grafana  "$GRAFANA" /api/health
cat <<BANNER

  Grafana   $GRAFANA  -> Explore -> Loki
  Live      {job="ralph", task="$TASK"}
  Rejects   {job="ralph", task="$TASK", event="reject"}
  Phases    {job="ralph", task="$TASK", event=~"phase_start|phase_done"}
  Stuck?    {job="ralph", task="$TASK", event="gate_oscillation"}

  Run log   $WORKDIR/.wiggum/features/$FEATURE/runs/<run_id>/run.log
  Gates     $WORKDIR/.wiggum/features/$FEATURE/gates/
  Prompts   $WORKDIR/.wiggum/features/$FEATURE/debug/invocations/   (--debug)
  Progress  $WORKDIR/.wiggum/features/$FEATURE/PROGRESS.md

  Stop      ./scripts/run-loop.sh --stop

BANNER

exec "$ORCH" \
  -w "$WORKDIR" \
  -s "$SPEC" \
  --spec-format speckit-tasks \
  --feature "$FEATURE" \
  --verification plan \
  "${LIVE[@]}" \
  --telemetry --loki-url http://127.0.0.1:3100 \
  --otel --otel-url http://127.0.0.1:4318
