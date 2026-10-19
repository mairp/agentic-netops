# Resume prompt — primary owner of the 004 MoL watch (single lane)

Grounded 2026-10-15 11:25 +04 from read-only checks. The previous primary-owner session was closed by
mistake around 11:12; the loop itself kept running. Only the owner watch died with it (its `watch.py`
and its safety-net check were background jobs of that session).

**Role.** You are the primary owner. Follow `evals/prompts/observe-mol-vs-infra.md` in full, including
all of its addenda. This file only records what changed since then. One lane: this run only, no other
features, no parallel owners. Evals stay on: every surprising cycle goes to `OBSERVATIONS.md` plus
`observations.jsonl` / `cases.jsonl` (next ids **O-39**, next EVAL ids after the highest in `cases.jsonl`).

## State at handoff (verify it; the run moves)

- Orchestrator alive under **`mol004-direct-resume3.service`** (run `20261015-090704-577322`), started
  09:07 by `direct-resume.sh` with the scratchpad `orch.environ`/`orch.cmdline` of session aa6ffc80.
  `mol004-direct-resume2` shows `failed` and can stay that way. The next relaunch unit is
  `mol004-direct-resume4`.
- Gates 1–3 approved. Phase 4, **attempt 2/30, proposer pass 1** since 09:27:47 (dsh session
  `session-a953914c…`, still writing at 11:20). Attempt 1 was rejected by the critic at 09:22
  (`GATE4-FEEDBACK.md`).
- **User decision, 09:2x:** T230/T243/T265 (invalid-YANG) were AMENDED in `specs/.../tasks.md`: they pass with a
  live proof that reaches the invalid-YANG apply step and evidence explaining that the lab has no SDC validating
  webhook. Backup: `/tmp/claude-0/-root-agentic-netops/aa6ffc80-fd88-4015-a953-e951c1de337f/scratchpad/tasks.md.bak-20261015-before-invalid-yang-amend`.
  Drift (T226/T261/T239/T162) and MTU/ECMP (T229/T264/T242/T16x) are NOT amended: they must go green. Do not
  re-open this decision.
- Proposer work since then (real fixes, not test weakening): `maximum-paths 2` in both bootstraps, ECMP
  flows 9→32, drift witness via vtysh interface description, overlay/VTEP and jumbo-MTU fixes in
  `lab/profiles/sonic-vm/bootstrap/configure-fabric.sh`, repeated `--reassert` (now `/tmp/reassert6.log`),
  then re-recording `q3-invalid-yang` (destructive).
- `run.log` line `>>> prompt block 'yield_contract' kept over budget (protected) … 180000` is a warning
  from prompt assembly, not a halt, even though the probe reports it in `halt`.
- Probe 11:21: alarms `chain:lab-sick` (stale chain9 mark from 00:59 on 10-14; no live chain) and
  `infra:host:clab-containers=6`. Lab redeployed ~11:06. All four SONiC guests are reachable, all units are
  active, and BGP is established (leaves 8, spines 12). **`client01` and `client02` are missing** from the 8-node
  topology. That may be the destructive test mid-flight. If they are still absent after the proposer's current
  step, raise it in an OWNER entry.

## First actions

1. `cd /root/agentic-netops/evals/observations/004-srv6-service-requests`; run the probe; read
   the tail of `.wiggum/run.log`, the last OWNER/OWNER-REPORT blocks in `F/PROGRESS.md`, and `standin.log`.
2. Start `python3 …/watch.py` in the background (no other watcher may run: check with `pgrep -f watch.py`).
3. Keep a safety-net check every ~30 minutes (watcher alive, no unanswered `wake-pending`).
4. On every wake, do one cycle per section 5, delete `wake-pending`, restart the watcher.
5. Do not stop until `# DONE — all 11 phase(s) approved` + `[OWNER-RESUME-EXIT] … rc=0`, then write
   `REPORT.md` (section 7) and stop `mol004-owner-standin.service`.
