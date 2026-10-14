#!/usr/bin/env bash
# Delta monitor for the 004 mixture-of-loops run. Stores previous snapshot in
# /tmp/mol004-monitor-state and prints only what changed since the last call.
RUN=/root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/.mixture-of-loops/runs/004-srv6-service-requests
WIG=/root/agentic-netops/.wiggum/features/004-srv6-service-requests
STATE=/tmp/mol004-monitor-state

now=$(date '+%H:%M:%S')
# Active run: 20261013-114053-3982362 (relaunched via `specstride resume` after the
# 2026-10-13 09:57 failed digest). Digest/Approved judged only on lines appended
# after this run's start so stale lines from the previous run cannot false-trigger.
RUN_START_LINE=$(grep -n 'proposer: phase 3 attempt 1/30' "$RUN/launcher.log" 2>/dev/null | tail -1 | cut -d: -f1)
RUN_START_LINE=${RUN_START_LINE:-0}
NEWLOG=""; [ "$RUN_START_LINE" -gt 0 ] 2>/dev/null && NEWLOG=$(tail -n +$RUN_START_LINE "$RUN/launcher.log" 2>/dev/null)
sup=alive; ps -p 4145226 >/dev/null 2>&1 || sup=DEAD
approved=$(grep -c 'APPROVED' "$RUN/launcher.log" 2>/dev/null)
phase=$(grep -oP '^===== PHASE \K[0-9]+' "$RUN/launcher.log" 2>/dev/null | tail -1)
pass=$(echo "$NEWLOG" | grep -oP 'proposer pass \K[0-9]+/30' | tail -1)
attempt=$(echo "$NEWLOG" | grep -oP 'attempt \K[0-9]+/30' | tail -1)
lastproof=$(ls -t "$WIG/gates/proofs" 2>/dev/null | grep -v '^\.' | head -1)
proofage=""
[ -n "$lastproof" ] && proofage=$(( $(date +%s) - $(stat -c %Y "$WIG/gates/proofs/$lastproof") ))
lastproofmt=$(stat -c %Y "$WIG/gates/proofs/$lastproof" 2>/dev/null)
newestany=$(find /root/agentic-netops /tmp/g3 -type f -not -path "*/.git/*" -not -path "*runs/20261012*" -newermt "-120 minutes" 2>/dev/null | xargs -r stat -c "%Y %n" 2>/dev/null | sort -rn | head -1)
nproofs=$(ls "$WIG/gates/proofs" 2>/dev/null | grep -vc '^\.')
nckpt=$(ls "$WIG/pass-checkpoints" 2>/dev/null | wc -l)
digest=$(echo "$NEWLOG" | grep -o '\[DIGEST\].*' | tail -1)

snap="sup=$sup approved=$approved phase=$phase pass=$pass attempt=$attempt lastproof=$lastproof lastproofmt=$lastproofmt newestany=$newestany nproofs=$nproofs nckpt=$nckpt digest=$digest"
echo "== $now =="
if [ -f "$STATE" ]; then
  prev=$(cat "$STATE")
  if [ "$prev" = "$snap" ]; then
    echo "no change: approved=$approved/11 phase=$phase pass=$pass lastproof=${lastproof}(${proofage}s old)"
  else
    echo "CHANGED since last check:"
    echo "  prev: $prev"
    echo "  curr: $snap"
    [ "$sup" = "DEAD" ] && echo "  !! SUPERVISOR DEAD"
    [ -n "$digest" ] && echo "  !! DIGEST: $digest"
  fi
else
  echo "baseline: $snap"
fi
printf '%s' "$snap" > "$STATE"
