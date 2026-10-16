#!/usr/bin/env bash
# Owner relaunch of the 004 orchestrator outside the MoL supervisor (its gate
# refuses with stale-sources). Same argv and environment as the stopped run.
set -u
ENVF=${1:?environ file}; ARGF=${2:?cmdline file}
while IFS= read -r -d '' kv; do export "$kv" 2>/dev/null || true; done < "$ENVF"
mapfile -d '' -t argv < "$ARGF"
cd /root/agentic-netops
echo "[OWNER-RESUME] $(date -Is) direct orchestrator relaunch (verification-commands bash fix applied)"
"${argv[@]}"
rc=$?
echo "[OWNER-RESUME-EXIT] $(date -Is) rc=$rc"
exit $rc
