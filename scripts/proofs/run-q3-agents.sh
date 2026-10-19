#!/usr/bin/env bash
# Proof q3-agents (plan 4-25): the whole plain-pytest suite — `cd agents && pytest`
# — green against the phase-4 tree (fabricplan per-kind plans, executor
# transports, provider NodeKind wiring).
#
# Same shape as scripts/proofs/run-p1-agents.sh (T015): declared to the
# verification gate by SCRIPT PATH, never wrapped in `bash -c`; agents/.venv
# is sourced here so the proof is self-contained (the bare system python has
# no langchain_core/ioa_observe — measured 2026-10-14, q3-agents first run);
# and AGENT_OTLP_HTTP_ENDPOINT points at a throwaway local OTLP sink so the
# captured bytes stay deterministic (the default endpoint is a cluster DNS
# name this host cannot resolve, whose exporter tracebacks raced into the
# phase-1 capture). Test outcomes are unchanged by both.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV_ACTIVATE="$REPO_ROOT/agents/.venv/bin/activate"
[[ -f "$VENV_ACTIVATE" ]] || { echo "run-q3-agents.sh: missing $VENV_ACTIVATE" >&2; exit 3; }
# shellcheck source=/dev/null
source "$VENV_ACTIVATE"

# Throwaway OTLP sink: accepts any POST and returns 200, logs nothing.
OTLP_SINK_PORT="${OTLP_SINK_PORT:-14319}"
export AGENT_OTLP_HTTP_ENDPOINT="http://127.0.0.1:${OTLP_SINK_PORT}"
python - "${OTLP_SINK_PORT}" >/dev/null 2>&1 <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class Sink(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), Sink).serve_forever()
PY
SINK_PID=$!
trap 'kill "${SINK_PID}" 2>/dev/null || true' EXIT
sink_up=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if (exec 3<>"/dev/tcp/127.0.0.1/${OTLP_SINK_PORT}") 2>/dev/null; then
    exec 3>&- 3<&- || true
    sink_up=1
    break
  fi
  sleep 0.2
done
if [[ "$sink_up" -ne 1 ]]; then
  echo "run-q3-agents.sh: local OTLP sink did not come up on 127.0.0.1:${OTLP_SINK_PORT}" >&2
  exit 3
fi

rc=0
cd "$REPO_ROOT/agents" && pytest || rc=$?
exit "$rc"
