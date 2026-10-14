# Phase 2 — accelerator pass (attempt 2)

An accelerator pass (proposer tools, narrowed prompt) already acted on the
diagnostician hint for: T005,T597
Its changes are in the tree. Do NOT redo them — verify they hold, then fix
whatever the critic still rejects.

## Files this pass changed (vs HEAD; 'new' = untracked)
- scripts/proofs/run-p2-t005-guard.sh	new

## The accelerator's own notes
# Phase 2 — accelerator note (attempt 6)

The diagnostician hint supplied with this pass was STALE: it is the attempt-2 hint
("restage the canonical verification plan onto the runner scripts"), which was already
planned and executed in attempt 3 — the plan at
`runs/20261012-052705-3104859/verification/verification-plan.json` (id
verification-0304bc4d682c2f771503, hash b5446cb0…) already points the four phase-2
entries at `bash scripts/proofs/run-<name>.sh`, and the attempt-3 gate rehearsal proved
it executes. Acting on it again would have changed nothing.

The pass therefore implemented the FRESH critic feedback (GATE2-FEEDBACK, verdict
2c313f49ec8b660b) instead, which named exactly two unmet criteria:

- T005: recorded a durable generation-guard artifact — `scripts/proofs/run-p2-t005-guard.sh`
  via `bash scripts/proof.sh p2-t005-guard -- …` (`gates/proofs/p2-t005-guard.{cmd,out}`,
  replay "no difference"). Because the live mapper legitimately carries the pinned T008
  change (`git diff --quiet -- agents/provisioning/mapper` is exit 1 in the worktree),
  the proof reconstructs the exact T005 tree state in a throwaway `git archive 89b497c7`
  checkout, shows the diff CLEAN (exit 0) immediately before regenerating, replays the
  live snapshot green with no flag first ("Done when"), then regenerates with
  UPDATE_BASELINE=1 to byte-IDENTICAL output (sha256 bb70f285…658b, 67 cases). The live
  tree was never written.
- T597: pure grounding restage — line-numbered slice
  `gates/proofs/p2-t597-review-record.txt` of `docs/SRV6_ACCEPTANCE_004.md` lines 46-86
  (the whole R1 record: why, before/after texts for classifier/mapper/refusal, and the
  named proofs q10-srv6 / q10-baseline / q10-guard / p1-agents). The doc itself was NOT
  edited.

Evidence spliced: attempt-5 archive with exactly three hunks (date line, T004/T005
region, T597 region). Nothing else touched; all previously confirmed criteria and their
backing files are byte-identical, and the verification plan was not modified (spec
source hash unchanged).

Nothing was left unfinished.
