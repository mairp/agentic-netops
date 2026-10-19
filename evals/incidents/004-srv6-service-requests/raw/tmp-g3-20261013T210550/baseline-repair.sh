#!/usr/bin/env bash
# baseline-repair.sh — pass-18 follow-up: the 04:10 baseline captures were
# recorded BEFORE the down-session State mask was added to baseline-capture.sh
# (spine02's seed iBGP rows point at a peer with no matching rows and its
# `timers connect 10` flips the State column Connect/Active every retry —
# that instability is what made A-dry report spine02 differ; spine01 + leaves
# were already ok after the seed-restore fix). This re-records the whole
# baseline group on a freshly restored seed, in canonical record order, with
# the masked script, then records the T105 receipt. Runs ONLY after the main
# chain is done (waits for /tmp/g3/runner.done).
set -u
cd /root/agentic-netops || exit 9
P=.wiggum/features/004-srv6-service-requests/gates/proofs
log() { echo "##### $(date +%H:%M:%S) $*"; }
step() { local n=$1; shift; log "START $n: $*"; "$@" > "/tmp/g3/$n.log" 2>&1; echo $? > "/tmp/g3/$n.rc"; log "RC $n=$(cat /tmp/g3/$n.rc)"; }

step R-seed bash scripts/spike/seed-restore.sh
step R-b-spine01 scripts/proof.sh spike-baseline-spine01 -- scripts/spike/baseline-capture.sh spine01
step R-b-spine02 scripts/proof.sh spike-baseline-spine02 -- scripts/spike/baseline-capture.sh spine02
step R-b-leaf01  scripts/proof.sh spike-baseline-leaf01  -- scripts/spike/baseline-capture.sh leaf01
step R-b-leaf02  scripts/proof.sh spike-baseline-leaf02  -- scripts/spike/baseline-capture.sh leaf02
step R-dry       scripts/proof.sh replay spike-baseline
step R-receipt   scripts/proof.sh spike-rerun-baseline -- scripts/proof.sh replay spike-baseline
if grep -q '^differ:' "$P/spike-rerun-baseline.out" 2>/dev/null; then
  echo differ > /tmp/g3/spike-rerun-baseline.verdict
else
  echo clean > /tmp/g3/spike-rerun-baseline.verdict
fi
{
  echo "R-seed=$(cat /tmp/g3/R-seed.rc 2>/dev/null)"
  echo "R-dry=$(cat /tmp/g3/R-dry.rc 2>/dev/null)"
  echo "spike-rerun-baseline=$(cat /tmp/g3/spike-rerun-baseline.verdict 2>/dev/null || echo missing)"
} > /tmp/g3/repair.summary 2>&1
echo "REPAIR-DONE $(date +%H:%M:%S)" > /tmp/g3/repair.done
log "REPAIR DONE — summary in /tmp/g3/repair.summary"
