# Phase 2 — accelerator pass (attempt 2)

An accelerator pass (proposer tools, narrowed prompt) already acted on the
diagnostician hint for: the criteria named in the critic feedback (prose, no IDs)
Its changes are in the tree. Do NOT redo them — verify they hold, then fix
whatever the critic still rejects.

## Files this pass changed (vs HEAD; 'new' = untracked)
- .mixture-of-loops/004-srv6-service-requests/verification-commands.json	+8	-16
- scripts/proofs/run-p1-agents.sh	new
- scripts/proofs/run-q10-baseline.sh	new
- scripts/proofs/run-q10-guard.sh	new
- scripts/proofs/run-q10-srv6.sh	new

## The accelerator's own notes
# GATE2-ACCELERATOR-NOTE — attempt 2 (T012-T015 restage)

Case: GROUNDING (per `GATE2-HINT.md`). Implementation and suite were already green; the four
LIVE proof criteria T012-T015 failed at the command layer: exit 126
(`/usr/bin/bash: /usr/bin/bash: cannot execute binary file`).

## Root cause
The four phase-2 proof commands were declared as argv `["bash", "-c", "cd agents && pytest …"]`.
The gate runs `executable + args` verbatim, i.e. `/usr/bin/bash bash -c "cd agents && pytest …"`:
with no `-c` of its own, the outer bash treats the first argument word `bash` as a SCRIPT FILE —
a binary — and refuses it (exit 126) before pytest starts. The commands that already pass
(`p1-proof-recorder-*`) declare bare script paths (`args: ["scripts/proof.sh", …]`) — that is
the shape the gate accepts.

## What changed (and nothing else)
1. **Four runner scripts created** — `scripts/proofs/run-q10-baseline.sh`,
   `scripts/proofs/run-q10-srv6.sh`, `scripts/proofs/run-q10-guard.sh`,
   `scripts/proofs/run-p1-agents.sh` (each: `set -euo pipefail`, source
   `agents/.venv/bin/activate`, `cd agents`, `exec pytest …`). Headers document why the
   command must never be wrapped in `bash -c`.
2. **Proofs restaged** — `bash scripts/proof.sh <name> -- scripts/proofs/run-<name>.sh` for
   all four; every record exited 0; the stored `<name>.cmd` is now the bare script path.
   Slices: `gates/proofs/p2-restage-scripts.txt`, `gates/proofs/p2-restage-proofs.txt`.
3. **Caller's contract patched** — `.mixture-of-loops/004-srv6-service-requests/verification-commands.json`:
   ONLY the `args` of the four phase-2 entries were rewritten to the script path
   (`p2-phrasings-baseline-pytest`, `p2-phrasings-srv6-pytest`, `p2-vocabulary-guard-pytest`,
   `p2-agents-pytest-full`; ids/phase/cwd/timeoutSec byte-identical; validated programmatically
   that no other entry changed). The same `bash -c` defect exists in later phases' entries —
   deliberately left alone (footprint rule; they are not this gate's unmet criteria).
4. **Criteria redeclared** — `specs/004-srv6-service-requests/tasks.md` T012-T015: the
   backticked command segment is now the script path (the inner pytest line kept as quoted
   prose). Editing tasks.md changes the spec projection, so the verification plan re-creates
   itself from the patched contract on the next orchestrator launch — by design; the declared
   ids are preserved so the gate re-runs exactly these four commands.
5. **Determinism fix inside the scripts** — they export `OBSERVE_TELEMETRY=false`: the tier's
   OTLP endpoint (`config/telemetry.py`) is a cluster DNS name this host cannot resolve, and
   the exporter's shutdown traceback raced into the captured output with nondeterministic
   length (that — not a test defect — is why full-suite replay used to flake). Test outcomes
   are unchanged: 304 passed, 4 skipped, 5 deselected.
6. **Evidence spliced** — `gates/GATE2-EVIDENCE.md` (atomic .tmp → mv): copy of
   `attempts/phase2/attempt1/GATE2-EVIDENCE.md` with ONLY the T012-T015 regions replaced
   (§1 rows 7-10, the replay-determinism paragraph, the §2 T012-T015 bullet); the rest is
   byte-identical (diff verified: exactly three hunks).

## Replay status after the restage
`replay q10` → 3 proof(s) checked, no difference · `replay p1-agents` → no difference ·
`replay selftest` (the command the phase gate itself executes) → no difference —
`gates/proofs/p2-restage-replay.txt`.

## Deliberately NOT touched
`scripts/proof.sh` (pinned by phase-1 criteria), every implementation file behind an
already-passing criterion, `testautomation/…/TEST_PLAN.md` and
`generated/verification.generated.json` (machine-regenerated projections), later phases'
command entries, and the pre-existing dirty files (`.gitignore`, `vendor/sonic-buildimage`,
`tmp_research/`, `versions.lock.yaml.bak`).
