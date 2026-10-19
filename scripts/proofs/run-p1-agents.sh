#!/usr/bin/env bash
# Proof p1-agents (plan 1-08): the whole plain-pytest suite —
# `cd agents && pytest`.
#
# Declared to the verification gate by SCRIPT PATH (exec'd as
# `/usr/bin/bash scripts/proofs/run-p1-agents.sh`), never wrapped in `bash -c`:
# the gate already runs bash, and a nested `bash -c` string is executed as
# `bash -c <script-file>` → exit 126 ("cannot execute binary file").
#
# The venv is sourced here so the proof is self-contained: agents/.venv carries
# the a2a package and the plugin set the recorded output expects.
#
# Telemetry determinism WITHOUT changing test behaviour: the e2e tests really
# exercise the instrumented pipeline, so the SDK must stay fully enabled
# (OTEL_SDK_DISABLED=true was tried and broke 85 of them — the instrumented
# code paths consume live span contexts). What made the captured output
# nondeterministic is narrower: the tier's default OTLP endpoint
# (agents/config/telemetry.py, AGENT_OTLP_HTTP_ENDPOINT) is a cluster DNS name
# this host cannot resolve, so the metrics exporter's periodic collect logged
# a "Exception while exporting metrics" traceback whose presence, count and
# embedded timestamps raced into the capture (it made proof replay flaky, not
# red). This runner therefore points AGENT_OTLP_HTTP_ENDPOINT — the variable
# that module actually reads — at a throwaway local OTLP sink (below) that
# answers 200 to every POST: exports behave exactly as in production (they
# succeed) but log nothing, so the captured bytes are deterministic. Test
# outcomes are unchanged: 304 passed, 4 skipped, 5 deselected.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV_ACTIVATE="$REPO_ROOT/agents/.venv/bin/activate"
[[ -f "$VENV_ACTIVATE" ]] || { echo "run-p1-agents.sh: missing $VENV_ACTIVATE" >&2; exit 3; }
# shellcheck source=/dev/null
source "$VENV_ACTIVATE"

# Throwaway OTLP sink: accepts any POST and returns 200, logs nothing.
OTLP_SINK_PORT="${OTLP_SINK_PORT:-14318}"
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
  echo "run-p1-agents.sh: local OTLP sink did not come up on 127.0.0.1:${OTLP_SINK_PORT}" >&2
  exit 3
fi

cd "$REPO_ROOT/agents"
rc=0
pytest || rc=$?
exit "$rc"
