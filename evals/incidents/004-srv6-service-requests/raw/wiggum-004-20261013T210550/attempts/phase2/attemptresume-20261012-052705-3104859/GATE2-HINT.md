# Phase 2 — diagnostician hint (attempt 2)

Generated because this phase's rejection reasons matched a NEW
unmet-criteria signature. NOT a critic verdict — a second opinion
with no grounding byte budget, meant to unblock a stuck loop faster.

CASE: GROUNDING

The gate is still executing the old “bash -c …” argv and never gets far enough to write the evidence file, hence the 126 error in attempt 1 and the “no phase-2-attempt-2.json” in attempt 2. The fixed runners exist and are green, but the canonical verification plan the critic runs wasn’t updated to use them.

What the critic needs and where:
- Use these wrapper scripts as the exact commands:
  - scripts/proofs/run-q10-baseline.sh
  - scripts/proofs/run-q10-srv6.sh
  - scripts/proofs/run-q10-guard.sh
  - scripts/proofs/run-p1-agents.sh
  Their content is shown in gates/proofs/p2-restage-scripts.txt (lines 1–26 in each section).
- Proof that they pass: see gates/proofs/q10-baseline.out, q10-srv6.out, q10-guard.out, and p1-agents.out.
- The corrected declarations are already in .mixture-of-loops/004-srv6-service-requests/verification-commands.json (lines 31–69).

Hint: Restage the canonical verification plan (the one at .wiggum/.../verification/verification-plan.json) so each Phase 2 entry runs “bash scripts/proofs/run-<name>.sh” instead of “bash -c 'cd agents && pytest …'”. Once the plan points to those four scripts, the gate will execute and write the evidence file.

