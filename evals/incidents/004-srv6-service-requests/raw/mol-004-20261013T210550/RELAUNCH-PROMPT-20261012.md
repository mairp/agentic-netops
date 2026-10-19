# RELAUNCH PROMPT — mixture-of-loops `004-srv6-service-requests` (fresh session handoff)

Copy everything below the line into a new agent session as its first message.
Last updated: 2026-10-12 ~06:1x +04.

---

## Objective

Drive the mixture-of-loops pipeline for feature `004-srv6-service-requests` to a
**terminal digest** (`[DIGEST] state=completed`) and deliver a closing report that
quotes all `[MOL-*]` lines verbatim from both the archived run and the active run.
Use the `mixture-of-loops` skill (mode auto, learning off). Track progress SILENTLY —
surface only anomalies and milestones.

## Current state (verify, don't assume — it may have advanced or died since)

- Active launcher supervisor pid **3104766** (was ALIVE at handoff; PPID 1, setsid-detached).
- Active run dir: `/root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/.mixture-of-loops/runs/004-srv6-service-requests/`
- Specstride run: `/root/agentic-netops/.wiggum/features/004-srv6-service-requests/runs/20261012-052705-3104859/`
  (resumed from phase-1 approval, commit `89b497c7`; phase 2 was in attempt 2/30 at handoff).
- Milestone log: `/root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/milestones.log`
  (appends APPROVED counts + terminal `[DIGEST]`; written by a detached watcher).
- Archived fatal run (the 2026-10-12 00:30:26 SIGINT incident, exit 130):
  `…/.mixture-of-loops/runs/004-srv6-service-requests.stopped-exit130-20261012/`
- Incident report (READ THIS FIRST for context):
  `/root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/INCIDENT-20261012-launcher-sigint.md`
- Fleet memory entry exists (qmd, type infra): "Mixture-of-loops launcher killed by
  harness idle-session sweep (INCIDENT 2026-10-12)" — recall with
  `/root/qmd-gateway/recall.sh "mixture-of-loops launcher killed setsid"`.

## Health check (do this first)

```bash
RUN=/root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/.mixture-of-loops/runs/004-srv6-service-requests
ps -o pid,etime -p 3104766 || echo "SUPERVISOR DEAD — check digest below"
tail -n 5 "$RUN/launcher.log"
grep -c APPROVED "$RUN/launcher.log"; tail -n 5 /root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/milestones.log
tail -n 3 /root/agentic-netops/.wiggum/features/004-srv6-service-requests/runs/20261012-052705-3104859/events.jsonl
```

- Supervisor alive → just monitor. Poll every ~10–15 min (sleep in a normal bash call,
  or re-check on each turn). Do NOT create long-lived DSH background jobs for this.
- Terminal `[DIGEST] state=completed` → collect `[MOL-*]` lines from BOTH run dirs,
  write the closing report, done.
- Terminal digest with `state=stopped|failed` → follow RELAUNCH RECIPE below.

## RELAUNCH RECIPE (if the pipeline died)

1. Read the digest `reason`. If `reason=interrupted` (external kill): that is the
   2026-10-12 incident class — proceed. If `reason=wall_budget`: report, don't relaunch.
2. **Always relaunch detached** — this is mandatory, the whole point of the incident:
   ```bash
   cd /root/agentic-netops/.mixture-of-loops/004-srv6-service-requests
   setsid env MOL_VIA=shell python3 .mixture-of-loops/scripts/supervise.py launch \
     --launcher ./run-004-srv6-service-requests.sh --mode auto \
     >> relaunch-$(date +%Y%m%d).log 2>&1 < /dev/null &
   ```
3. If the gate refuses with `stale-sources` (tasks.md changed since the contract was
   promoted — happens after any pipeline progress): re-derive + transplant, NOT a blind
   retry:
   - `python3 .mixture-of-loops/scripts/bootstrap_contract.py --workdir /root/agentic-netops …`
     (restore `specs/004-srv6-service-requests/verification-commands.json` from the
     workdir copy if flagged missing)
   - Transplant per-obligation semantic fields (producer, disposition, evidence,
     stage_ids, timing, verification_ids, rationale) + settled findings + stage graph
     from the last promoted contract
     (`…/.mixture-of-loops/generated/004-srv6-service-requests/draft-relaunch2-mapped.json`
     as of handoff) onto the fresh draft — obligation IDs matched by ID (628/632 were
     identical last time; review each delta individually).
   - Merge `/root/.dsh-basic` into `authorized_roots` if the validator flags it.
   - `validate_contract.py --promote` → `render_launcher.py` → `bash -n` the launcher →
     archive the dead run dir (`mv runs/004-srv6-service-requests runs/004-srv6-service-requests.stopped-<reason>-<date>`)
     → relaunch detached as in step 2.
4. Restart the milestone watcher detached too:
   ```bash
   setsid bash /root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/milestone-watch.sh \
     >> /root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/milestones.log 2>&1 < /dev/null &
   ```

## Hard rules

- NEVER launch `supervise.py` in the foreground or via a plain DSH background job —
  the harness's idle-session sweep killed the 2026-10-12 run that way (exit 130).
- Do NOT edit anything under `/root/specstride/` while a run is live, and do NOT commit
  in `/root/agentic-netops` (the pipeline's workspace).
- Diagnostician `CONTEXT_WINDOW_EXCEEDED` errors are FIXED as of 2026-10-12
  (specstride commit `665e20d`, PR https://github.com/mairp/specstride/pull/134 —
  25% window haircut in `run_diagnostician`). If they recur anyway, the loop still
  self-recovers (archived attempt + accelerator hint); don't intervene for them alone.
- Phase-2 rejections are normal iteration (30 attempts allowed). Intervene only on:
  terminal digest, supervisor death without a digest, or attempts burned past ~20.
- Budgets at handoff: relaunch budget 2/2 UNUSED; wall-clock ceiling ~3.11e7 s.

## Deliverable

Closing report: pipeline verdict, phase-by-phase approval summary (11 phases),
ALL `[MOL-*]` lines verbatim (archived dir first, then active), total wall time,
attempts used per phase, and the digest line. Then state plainly that the goal is done.
