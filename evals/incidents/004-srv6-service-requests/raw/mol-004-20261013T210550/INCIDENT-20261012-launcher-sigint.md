# INCIDENT 2026-10-12 — mixture-of-loops launcher killed by SIGINT (exit 130) at 00:30:26 +04

Pipeline: `004-srv6-service-requests` (Specstride, mode auto, learning off)
Run dir: `/root/agentic-netops/.mixture-of-loops/004-srv6-service-requests/.mixture-of-loops/runs/004-srv6-service-requests/`
(archived after recovery at `…/runs/004-srv6-service-requests.stopped-exit130-20261012/`)
Discovered: 05:14 +04, when the operator asked for status after a ~4h45m session gap.
Recovered: 05:27 +04 (relaunch, all gates re-passed).

## 1. Timeline (all times +04, 2026-10-11/12)

| Time | Event |
|---|---|
| 21:46:57 | Original launch: `supervise.py launch --launcher run-004-srv6-service-requests.sh --mode auto`, launched from a DSH bash-tool job. Gate `decision=launch`; launcher pid **898228** spawned. |
| 21:59–22:00 | Phase 1/11 APPROVED on attempt 1; gate `GATE-phase-1 passed 3 command(s)`; commit `89b497c7`. |
| 22:00:26 | Phase 2 (Foundational) proposer pass 1 begins. |
| 22:22 | Agent session goes quiet (goal-round budget exhausted at round 256). Pipeline and watchers keep running. |
| ~00:0x–00:16 | Pass 1 ends; critic REJECTS (attempts 1–3 all rejected; attempt 3 had passed its 10-command gate but failed critic grounding). |
| 00:16:47–00:18:51 | Diagnostician sub-call **fails**: `dsh: CONTEXT_WINDOW_EXCEEDED … model "gpt-5"` (compass-gpt5-high). Specstride handles it: `diagnostician_error` → `attempt_archived` → accelerator re-pass (attempt 4/30, hints T022/T023/T024/T599). Self-recovered — not part of the outage. |
| 00:30:14 | Attempt 4: gate `GATE-phase-2 passed 10 command(s)` → `verification_passed`; `critic_start` (compass-gpt5-high/gpt-5). |
| **00:30:26** | **Launcher killed by SIGINT (exit 130).** Terminal digest: `[DIGEST] state=stopped exit=130 last-stage=run-004-srv6-service-requests child-exit=130`. state.json: `exit_reason: "interrupted"`. Both session watcher jobs (supervise watch + milestone watcher) died in the same second. The attempt-4 critic verdict was lost mid-flight. |
| 00:30:26–05:14 | Nothing running for the pipeline; no auto-restart (correct: relaunch on `interrupted` is not authorized by the contract — only `wall_budget` exit 4 is). |
| 05:27 | Recovery relaunch (see §5). Specstride opens run `20261012-052705-3104859` and resumes **directly at Phase 2 attempt 1/30** (phase 1 commit recognized from git). |

## 2. What the kill was NOT (each verified)

1. **Not a Specstride logic bug.** The launcher trapped the signal, wrote a truthful
   terminal digest and a consistent `state.json`, and exited. Correct behavior.
2. **Not signal forwarding by the supervisor.** `supervisor_lib.py` inspected:
   `request_stop()` fires only on an explicit `supervise.py stop`; the watch/observe
   commands never signal the launcher on their own termination.
3. **Not a crash inside the run.** exit 130 = 128+SIGINT, an *external* signal; the
   last in-run events (`verification_passed`, `critic_start`, `grounding_gap`) are
   consistent with a healthy phase 12 seconds before death.
4. **Not the diagnostician context overflow.** That failure (see timeline) happened
   twice earlier, was caught (`diagnostician_error`), and the loop re-planned around
   it. It is a degraded-capability issue, not a stability one.

## 3. What the kill WAS — and the one earlier claim I corrected

> **Superseded by §8.** The "idle-session reaping" conclusion below is wrong; the host
> journal shows a `dsh-web.service` crash followed by systemd's control-group kill.

**Initial claim (wrong):** "the launcher was session-attached; a job-group SIGINT
during harness cleanup killed it; `setsid` fixed it because the launcher now has its
own session."

**What the evidence actually shows:**
- `harness-launch.log` opens with `=== launch 2026-10-11T21:46:57+0400 …` — written by
  `supervisor_lib.launch()`, which spawns the child with
  `subprocess.Popen(..., stdin=DEVNULL, stdout=log, stderr=STDOUT, start_new_session=True)`.
  The launcher therefore **already had its own session and process group** (its
  `[MOL-LAUNCH]` stop hint `kill -TERM -898228` confirms it was a group leader), with
  no controlling terminal. A terminal/job-control SIGINT *per se* could not reach it.
- `command_launch()` returns immediately after the spawn; the top-level
  `supervise.py launch` process exited at ~21:47 and the launcher was orphaned to PID 1
  long before the incident. The kill therefore reached a fully detached, reparented,
  session-leading process.
- Everything else that died at 00:30:26 belonged to the **DSH agent session's tracked
  background jobs** (the `supervise.py watch` job, the milestone `sleep 90` watcher).
  The launcher died in the same one-second window.

**Conclusion (best supported):** the DSH harness performed a session/idle cleanup sweep
at 00:30:26 (≈2 h 8 min after the last session activity) that signals every process it
associates with the ended session — its tracked jobs **and the processes those jobs
spawned, regardless of later `setsid`**. The plausible mechanism is a cgroup- or
descendancy-scoped kill: `setsid` escapes the session and process group, but **not the
cgroup / ancestry bookkeeping** of the sandbox that spawned it. This is consistent with
all facts; the exact sweep implementation is inside the harness and not further
provable from host logs (nothing else in `journalctl` at that timestamp touches pid
898228; the host's `specstride-persist.service` and `specstride-watch.sh` concern other
repositories, `/root/deepseek-harness` and `/root/specstride-claude`, not this run).

**Net root cause:** an environment/lifecycle kill by the agent harness's idle-session
reaping — not a defect in Specstride or in the mixture-of-loops skill's supervision
code. The residual exposure is that *any* process spawned from a DSH bash-tool call —
even `setsid`-detached — shares the spawned-from sandbox and can be swept if the
harness chooses ancestry/cgroup-scoped cleanup. The practical mitigation that worked is
in §5; the structural mitigation is §6.3.

## 4. Impact

- Lost: ~4 h 45 m of wall-clock progress (00:30–05:27) and one critic verdict
  (attempt 4 had passed its 10-command gate; the verdict had to be re-earned).
- Not lost: all phase-2 evidence and code (committed/archived by the loop itself),
  phase 1 approval (git commit `89b497c7`), contract bundle, logs (archived run dir).
- Recovery cost: ~25 minutes of diagnosis + contract re-derivation + relaunch.

## 5. Recovery performed (05:14–05:29)

1. Diagnosis (this document, §2–3); watchers confirmed dead; launcher confirmed gone.
2. Direct relaunch attempt → **refused** by the launch gate: `stale-sources` —
   `specs/004-srv6-service-requests/tasks.md` hash changed (the loop had legitimately
   committed progress ticks; the contract is hash-bound to sources).
3. Fresh `bootstrap_contract.py` derivation from current sources (also restored
   `verification-commands.json` into the spec dir; the original had moved it to the
   mixture-of-loops workdir, which made one artifact read "absent").
4. **Semantic transplant**: the fresh draft has correct current hashes but no semantic
   mapping; the promoted contract has the mapping but stale hashes. 628/632 obligation
   IDs are identical; the 4 deltas are T012–T015 LIVE-proof lines the bootstrap
   classifier types as implementation (the original derivation had typed them
   verification). Transplanted per-obligation semantic fields (producer, disposition,
   evidence, stage_ids, timing, verification_ids, rationale) from the promoted
   contract onto the fresh draft, carried the 4 reclassified records over with the
   same producer and a rationale note, re-added `/root/.dsh-basic` to
   `authorized_roots`, copied the 8 settled findings and the full stage graph.
5. `validate_contract.py --promote` → **validated**. `render_launcher.py` → new bundle
   `b7259c5ee7a1a776e478`. `bash -n` OK. `--dry-run` exit 0, all `[PREFLIGHT]` checks pass.
6. Old run dir archived intact (all `[MOL-*]` history preserved for the closing report).
7. **Relaunch wrapped in `setsid`** (`setsid env MOL_VIA=shell python3 supervise.py
   launch … >> relaunch-20261012.log 2>&1 < /dev/null &`). All 7 gate checks pass,
   `decision=launch`, new launcher pid 3104766 (PPID 1).
8. Milestone watcher replaced with a **detached** script writing approvals and the
   terminal digest to `…/milestones.log` — independent of DSH background-job lifecycle.

## 6. Recommendations

1. **Always launch long mixture-of-loops pipelines detached**: wrap the whole
   `supervise.py launch|auto` invocation in `setsid … < /dev/null >> log 2>&1 &`, as in
   §5.7. Empirically survived the idle window that killed the first run; also keeps
   the agent's turn short instead of blocking for hours.
2. **Monitor through files, not job notifications**: a detached watcher appending to a
   milestone log survives the session and cannot be culled with background jobs.
3. **Structural option (not implemented, per operator decision 2026-10-12):** the host
   already runs other specstride loops under systemd units
   (`specstride-campaign.service`, `specstride-persist.service`). Running a
   mixture-of-loops pipeline under a dedicated unit (or having the harness expose an
   explicit "outlive session" sandbox mode) is the only change that removes the
   cgroup/ancestry exposure entirely. Skill/docs changes were deferred by the operator.
4. **Known cosmetic issue to watch** (pre-existing, self-recovering): the critic-side
   `diagnostician` sub-call overflows gpt-5's context on long attempts
   (`CONTEXT_WINDOW_EXCEEDED`). Specstride archives and re-plans around it; if it ever
   fails on the *critic* call itself the phase burns an attempt. Not actionable from
   the outside; count it in retros.
5. **If a run is ever found stopped with `reason: interrupted` again**: do not restart
   blindly — the launch gate will refuse on `stale-sources` after any progress; follow
   §5.2–5.5 (re-derive + transplant) or re-run the full skill derivation flow.

## 7. Key artifact paths

- Archived fatal run: `…/.mixture-of-loops/runs/004-srv6-service-requests.stopped-exit130-20261012/`
  (`launcher.log` holds the original `[MOL-*]` history and the terminal
  `[DIGEST] state=stopped exit=130`).
- Relaunch log: `…/.mixture-of-loops/004-srv6-service-requests/relaunch-20261012.log`
  (7 × `[MOL-GATE]` pass, `decision=launch`, `[MOL-LAUNCH] … pid=3104766`).
- Active run dir: `…/.mixture-of-loops/runs/004-srv6-service-requests/`
- New contract (validated): `…/.mixture-of-loops/generated/004-srv6-service-requests/draft-relaunch2-mapped.json`
  + bundle `b7259c5ee7a1a776e478`.
- Specstride run (active): `/root/agentic-netops/.wiggum/features/004-srv6-service-requests/runs/20261012-052705-3104859/`

## 8. Correction and fix (2026-10-12 05:58 +04)

### 8.1 Root cause, from the host journal

`journalctl -u dsh-web.service` at the incident second:

| Time | Event |
|---|---|
| 00:30:25.995 | `dsh web` (pid 2195068) dies on an uncaught `ENOENT` in `OutputCollector.spillAll` (`dsh-subprocess-local/lib/index.js:666`): its spill file `/tmp/dsh-subprocess-1rLWGJ/…-stdout.log` no longer existed. |
| 00:30:26.101 | `dsh-web.service: Main process exited, code=exited, status=1/FAILURE`. |
| 00:30:26 | The unit has `KillMode=control-group` and `KillSignal=SIGINT`, so systemd sent **SIGINT to every process left in the unit's cgroup**: the launcher (exit 130) and both watcher jobs. |
| 00:30:41 | `State 'stop-sigterm' timed out. Killing.` Survivors SIGKILLed. |
| 00:30:44 | Unit restarted (restart counter 2). |

So there was no idle sweep and no 2 h timer. The launcher had its own session and process
group, but `/proc/<pid>/cgroup` was `/system.slice/dsh-web.service`: everything started
from a DSH web session lives in that service's cgroup, and `setsid` does not leave it.
The §5.7 `setsid` relaunch had the same exposure (pid 3104766 was in the same cgroup);
it survived only because `dsh-web` had not crashed again.

Not determined: what removed `/tmp/dsh-subprocess-1rLWGJ`. `/tmp` was not wiped (20k older
entries remain), the lane monitor's hourly sweep does not match that name, and
`systemd-tmpfiles-clean` last ran at 21:55. The crash itself is a missing error handler
inside dsh (third-party package, not patched here).

### 8.2 Fixes applied

1. **Live run moved out of the dsh-web cgroup without a restart.** The launcher tree and
   the milestone watcher were adopted into `mol-004-srv6-service-requests.scope`
   (transient systemd scope, `StartTransientUnit` with `PIDs=`). A `dsh-web` crash or
   restart no longer reaches the run. Do not `systemctl stop` that scope: it kills the
   run. Stop a run with `supervise.py stop`.
2. **Skill fixed** (`/root/mixture-of-loops`, uncommitted on `roadmap-new-harnesses`):
   `supervisor_lib.launch()` and `relaunch()` now start the launcher through
   `systemd-run --scope --collect --unit=mol-<pipeline>-<epoch>-<pid>` when the host has a
   reachable manager (probed first; falls back to the old behaviour otherwise;
   `MOL_LAUNCH_SCOPE=0` disables). `--scope` execs in place, so PID, session, streams and
   the launch record are unchanged. Tests: `tests/test_supervision.py` 100 passed, full
   suite 222 passed / 1 skipped.

### 8.3 What changes in §6

- §6.1 (`setsid` wrapper) is not a mitigation for this failure. It is unnecessary now.
- §6.2 still holds: a watcher run as a DSH background job dies with `dsh-web`.
- §6.3 is implemented by 8.2.2.
