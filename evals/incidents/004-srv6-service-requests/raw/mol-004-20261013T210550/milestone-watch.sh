#!/bin/bash
# milestone-watch.sh — milestone-watcher for the ACTIVE run (rewritten 2026-10-13
# after relaunch: the previous version hardcoded the dead 2026-10-12 supervisor
# pid and matched pre-existing [DIGEST] lines from the earlier run, exiting at once).
RUN=/root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/.mixture-of-loops/runs/004-srv6-service-requests
OUT=/root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/milestones.log
ORCH_PID=4145257          # orchestrator of run started 2026-10-13 12:02:42 via supervise.py (supervisor 4145226)
START_LINES=$(wc -l < "$RUN/launcher.log" 2>/dev/null || echo 0)
LAST=0
while true; do
  # APPROVED milestones only count lines written after this watcher started
  A=$(tail -n +"$((START_LINES + 1))" "$RUN/launcher.log" 2>/dev/null | grep -c 'APPROVED'); A=${A:-0}
  if [ "$A" != "$LAST" ]; then echo "$(date +%H:%M:%S) APPROVED-THIS-RUN=$A" >> "$OUT"; LAST=$A; fi
  # terminal digest: only a line appended after start
  if tail -n +"$((START_LINES + 1))" "$RUN/launcher.log" 2>/dev/null | grep -qE '^\[DIGEST\] state=(completed|stopped|failed)'; then
    echo "$(date +%H:%M:%S) TERMINAL:" >> "$OUT"
    tail -n +"$((START_LINES + 1))" "$RUN/launcher.log" | grep -E '^\[DIGEST\]' >> "$OUT"; break
  fi
  if ! kill -0 "$ORCH_PID" 2>/dev/null; then
    echo "$(date +%H:%M:%S) ORCH-$ORCH_PID-EXIT" >> "$OUT"
    tail -n +"$((START_LINES + 1))" "$RUN/launcher.log" | grep -E '^\[DIGEST\]' >> "$OUT"; break
  fi
  sleep 90
done
