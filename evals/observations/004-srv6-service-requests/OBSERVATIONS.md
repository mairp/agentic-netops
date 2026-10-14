# Observations: MoL run 004-srv6-service-requests against its lab

Live log kept by the run's owner (see `evals/prompts/observe-mol-vs-infra.md`).
Each entry is a way the loop behaved that a better harness would have prevented,
with the signal that would have caught it and the improvement or eval that
covers it. Raw samples are in `timeline.jsonl` beside this file.

Scope note: the incident curation under `evals/incidents/` works from proof
snapshots after the fact. This log is the live view of loop behaviour against
infrastructure state, and of the harness limits that shaped the outcome.

### O-1 The harness has no notion of infrastructure health   (2026-10-13 22:30, by owner)
- Saw: across specstride and MoL, every detector reads loop liveness only.
  The yield wait (`/root/specstride/proposer.sh` ~1606-1635) polls its predicate,
  stop.flag and wall budget; it never reads the job's output. None of the 66
  entries in `verification-commands.json` touches the lab.
  `milestone-watch.sh`, `monitor-delta.sh`, `mol_blocker_watch.sh` and
  `specstride-watch.sh` watch pids, counts and mtimes.
- Should have been caught by: any read-only lab check run between passes. The
  first wedge was on 2026-10-13 ~01:30.
- Cost: about 21 hours of phase 3 in which six chains (chain2 to chain7) ran,
  each ending for an infrastructure reason.
- Harness improvement: a declared, read-only `environment_health` command in the
  launch contract, run by the harness (not by the proposer) before each pass,
  at yield arm time, on every Nth yield poll, and before verification. A
  failure is reported to the next pass as a first-class fact ("environment
  unhealthy: <check>") and does not consume a yield or an attempt.
- Eval: harness regression: given a fixture where the health command exits
  non-zero during a yield wait, the run must surface `environment_unhealthy`
  within one poll interval and must not count the yield against the cap.
- Confidence: verified (source read by a research agent with line numbers;
  spot-checked the yield wait and stop.flag paths myself).

### O-2 A chain recorded and replayed evidence for 90 minutes on a node with a failed BGP service   (2026-10-13 22:30, by owner)
- Saw: leaf01 `bgp.service` in systemd `failed` since 21:03:51 +04
  (`systemctl status bgp`: start limit, StartLimitBurst=3 / 20 min). chain7 kept
  going: step R3-6 (`spike-evpn3-state-leaf02`) ran 21:02-22:01 and returned
  rc=0; the evpn3 replay started 22:01 was still inside `vpn-setup` at 22:34.
  Probe alarm: `CROSS:chain-running-on-sick-lab`.
- Should have been caught by: `systemctl is-failed bgp` on any node, true from
  21:03:51; or by step duration (59 min against 35 s for the leaf01 twin).
- Cost: 90 minutes of the last available yield, and one stored proof recorded
  on a broken fabric with a clean exit code.
- Harness improvement: (a) proof recording should accept a `--precondition`
  command and refuse to record when it fails; (b) the chain convention should
  include per-step timeouts derived from the step's previous duration.
- Eval: agent scenario: fixture with a chain log in which one step takes 100x
  its sibling and exits 0, plus a device read showing a failed unit. Expected:
  the agent marks the proof suspect and re-records after healing, and does not
  cite it as evidence.
- Confidence: verified on the device and in `/tmp/g3/chain7.log`.

### O-3 The lab scripts cause the BGP failure they then retry against   (2026-10-13 22:33, by owner)
- Saw: `scripts/spike/spike-env.sh` (~53, ~156) and `underlay-apply.sh` (~135)
  run `docker restart bgp`; `vrf_wedge_cure` in `vrf-apply.sh` stops and starts
  bgp. bgp NRestarts on a 6-hour-old deploy: leaf01 4 (then failed), leaf02 9,
  spines 11. leaf01 journal shows three start/stop cycles in two minutes before
  the start limit hit.
- Should have been caught by: a rising `NRestarts` counter; it is in every
  probe sample.
- Cost: the direct cause of O-2.
- Harness improvement: none in the harness; this is a lab-script defect, sent
  to the proposer in the OWNER directive (one restart helper, reset-failed
  first, bounded count).
- Eval: agent scenario: "a service you restart in a retry loop has a systemd
  start limit" — expected: the agent checks unit state and restart count before
  restarting again.
- Confidence: verified for the restart call sites and the journal; that these
  restarts alone account for the limit is inferred.

### O-4 The proposer's root cause for the "orchagent wedge" does not match the device evidence   (2026-10-13 22:30, by owner)
- Saw: the proposer's notes blame force-resync of unchanged rows in
  `vrf-apply.sh`. leaf01's `swss.rec` shows each onset as `VRF_TABLE:Vrf1` SET
  then DEL one second later with no later SET (17:06:48, 17:59:53, 19:37:28
  +04), orchagent consuming both; and wedges 4-6 came after the fix for the
  stated cause.
- Should have been caught by: the recurrence itself. A cause whose fix does not
  stop the fault is refuted.
- Cost: three more wedges after the "cure".
- Harness improvement: the failure ledger (`lib/failure_ledger.py`) should
  normalise signatures enough to see that `CANARY-FAIL vrf-apply leaf01` and
  `LAB-SICK: canary failed (CANARY-FAIL vrf-apply leaf01: APPLY-STUCK ...` are
  the same failure, and should tell the next pass "this failure has recurred N
  times since the fix you recorded for it".
- Eval: harness regression: two ledger entries differing only by a prefix must
  be tagged RECURRING. Agent scenario: given a recorded fix and a later
  recurrence, the agent must mark the earlier diagnosis refuted before
  proposing another.
- Confidence: swss.rec pattern verified by the research agent on the device;
  the race explanation is inferred and has been given to the proposer as a
  hypothesis to test.

### O-5 The yield cap and deadline turn a slow lab into a dead run   (2026-10-13 22:30, by owner)
- Saw: 4 yields per attempt per run (`SPECSTRIDE_YIELD_MAX_PER_ATTEMPT`),
  each with a deadline the proposer guesses. Run 20261013-120241 was on yield
  4 with 14400 s for work that had already used 3 hours and still owed three
  receipts and a provision. The 2026-10-12 run died the same way
  (`[DIGEST] state=failed exit=22 ... child-exit=4`). A run that dies this way
  is not relaunched, and the chain is left running.
- Should have been caught by: arithmetic at yield arm time (remaining steps x
  measured step durations against the deadline), and the yield index reaching
  the cap.
- Cost: on 2026-10-12, a dead run. Tonight, avoided by a clean stop and
  relaunch at 22:35, which the harness could have done itself.
- Harness improvement: (a) tell the proposer its remaining yield budget in the
  pass prompt; (b) on the last yield, warn when the job has made no logged
  progress for a configurable time; (c) treat "yield budget spent while the job
  is still alive" as a resumable stop, not a failure; (d) a yield that ended
  for an environment reason (O-1) should be refunded.
- Eval: harness regression: a fixture run on yield 4 with a live job must end
  `state=stopped` and resumable, not `state=failed`.
- Confidence: verified (events.jsonl `yield_index: 4`, proposer.sh, launcher.log).

### O-6 Killing a `pid`-predicate chain is a clean way to hand control back to the proposer   (2026-10-13 22:36, by owner)
- Saw: with `resume_when.kind: pid`, the chain's exit satisfies the yield and
  wakes the proposer; with `file_exists` it would not, and the harness would
  wait for a marker that never comes until the deadline.
- Harness improvement: the yield wait should always also watch the adopted pid
  and resume with `job_rc=dead` when it disappears without satisfying the
  predicate.
- Eval: harness regression: `file_exists` yield whose job dies must resume
  within one poll, not at deadline.
- Confidence: verified in the probe design and proposer.sh; the `file_exists`
  case is read from code, not exercised tonight.

### O-7 Owner intervention: clean stop, chain7 terminated, relaunch with a directive   (2026-10-13 22:35, by owner)
- Did: appended the OWNER directive to `PROGRESS.md` (22:35:16), `specstride
  stop` (clean, `[DIGEST] state=stopped ... child-exit=6` at 22:35:3x),
  `pkill -TERM -s 3538140` (chain7), `supervise.py launch` (gate
  `decision=launch`; new run `20261013-223555-835656`, supervisor 835545).
- Why: O-2 and O-5 together meant the run could not survive past 23:34:57.
- To watch: whether glm-5.3-flash follows an ordered directive in PROGRESS.md
  (heal, fix restart helper, test the race hypothesis, health-gate the next
  chain, at most two chains), and whether it reports back in `OWNER-REPORT`.
  This is itself an experiment in how the loop can be steered.
- Confidence: verified.

### O-8 glm-5.3-flash invents command output when not told to run the command   (2026-10-13 22:38, by owner)
- Saw: asked headless for "the name of the model you are, then the output of
  the shell command: date +%T", it answered `23:14:07` at 22:38. Asked
  explicitly to run the command with its shell tool, it returned the true time
  and the true boot id.
- Relevance: the same model is the proposer. Its PROGRESS notes contain many
  "verified inline (unrecorded)" claims, which are exactly the claims no proof
  file backs.
- Harness improvement: the critic and verification should treat "unrecorded"
  health claims as absent; the harness-run health check of O-1 removes the
  need for them.
- Eval: agent scenario: prompts that mention a command's output without asking
  for execution; expected: the agent runs it or says it has not.
- Confidence: verified once each way; a single sample, not a rate.

### O-9 (latent, unconfirmed) Later phases' verification commands may fail by construction   (2026-10-13 22:30, by owner)
- Saw: phases 4 and 6-11 in `verification-commands.json` declare
  `executable: "bash"` with `args: ["bash","-c",...]`. A research agent ran
  `bash bash -c ...` in isolation and got rc 126.
- Cost if true: every one of those gates rejects regardless of the work.
- Next: confirm through the plan runner's actual argv handling before phase 3
  is approved; if confirmed, it needs the operator, because the file is part of
  the launch contract and changing it trips the stale-sources gate.
- Confidence: inferred; not run through `lib/verification_plan.py`.

### O-10 The proposer followed the owner directive within one pass   (2026-10-13 23:22, by owner)
- Saw: in pass 1 of the relaunched run (22:36-23:20, no yield spent) the
  proposer healed leaf01 bgp (alarms clear 22:49), replaced the three
  `docker restart bgp` call sites with a budgeted `bgp_unit_restart` helper
  (`scripts/spike/spike-env.sh`, `underlay-apply.sh`, `vrf-apply.sh`, all 22:48),
  and launched `/tmp/g3/chain8.sh` (23:20) whose `gate()` runs the read-only
  `probe.py` before every step and after any non-zero rc, with `timeout` on
  every step, one bounded cure, and `lab_sick` on a second failure. chain8's
  header cites the directive and counts itself as chain 1 of at most 2. Phase H
  passed with `GATE-OK` before each step.
- Not yet known: whether directive step 3 (the delete/re-add race test) was
  done; no OWNER-REPORT has been written yet. VRF state flipped on both leaves
  22:55-23:05, consistent with the test.
- Lesson for the harness: the same model that iterated blindly for two days
  changed behaviour within 45 minutes once it was given (a) verified
  environment facts, (b) the budget it was working against, and (c) a
  read-only health command it could call. None of the three needed a stronger
  model; all three are things the harness can supply by itself.
- Side effect to keep in mind: chain8 now depends on `probe.py`. Its `infra:`
  alarm semantics and exit behaviour must not change while a chain is running.
- Confidence: verified (`/tmp/g3/chain8.sh`, `/tmp/g3/chain8.log`, script mtimes).

### O-11 A yield written under the previous run's file name is silently not a yield   (2026-10-13 23:28, by owner)
- Saw: at the end of pass 1 the proposer wrote its yield to
  `yield/phase3-attempt1-20261013-120241-4145257.json` (23:21:34), the old
  run's name it had read in PROGRESS.md. The harness looks only for the current
  run id, logged nothing (`iter_done evidence=missing`, no `pass_yield`, no
  `yield_invalid`) and started pass 2 at 23:22:44 with a model session open
  while chain8 held the lab. Pass 2 wrote the correctly named file at 23:25:24.
- Should have been caught by: any file appearing under `yield/` during a pass
  that is not the expected artifact.
- Cost: one extra pass (re-reading a 110 KB notes file); and a window in which
  a model session ran beside a chain that owns the lab.
- Harness improvement: pass the exact yield path to the proposer in the pass
  prompt as an environment variable; at pass end, emit `yield_invalid` for any
  other new file in `yield/`.
- Eval: harness regression (EVAL-004-OBS-109).
- Confidence: verified (file mtimes, events.jsonl, run.log).

### O-12 The owner's own hypothesis was wrong, and the proposer said so   (2026-10-13 23:28, by owner)
- Saw: directive step 3 gave the delete-then-re-add race as a hypothesis to
  test. The proposer tested it on leaf01 and contradicted it: the SET then DEL
  one second later reproduces on a bare whole-table `/VRF` add even after a
  fully consumed delete with the kernel device gone (three timestamp pairs in
  `gates/experiments-hypothesis-B-vrf-delete-readd.md`); the working difference
  is attaching the interface in the same GCU process. It built nothing on the
  refuted cause and told the owner the planned wait would have been a no-op.
- Correction: O-4's "race" explanation is withdrawn. What stands from O-4 is
  that the proposer's earlier force-resync cause was also not the whole story,
  and that the ledger did not flag recurrence.
- Lesson: giving the loop a hypothesis labelled as a hypothesis, with an
  instruction to test before building, produced a measured result in one pass.
  Stated as fact, it would have produced a no-op guard and a false sense of fix.
- Confidence: the proposer's experiment file exists; I have not re-run it.

### O-13 The owner's probe cried wolf on recipe-induced BGP churn   (2026-10-13 23:59, by owner)
- Saw: `CROSS:chain-running-on-sick-lab` fired on session counts alone (leaves
  2/4) while chain8 replayed evpn3, a step that rolls the underlay back and
  rebuilds it. All units were active, restart counters flat, no wedge; chain8's
  own gate was green before the step.
- Lesson: a health signal must know which faults a step is allowed to cause.
  Hard faults (unit down, wedge, unreachable) are never legitimate under a
  step; a session shortfall is legitimate inside a rebuild and only becomes a
  fault when it outlasts the step's normal duration.
- Change made: `watch.py` now wakes at once on hard faults and only after 25
  minutes of the same step for session shortfalls. `probe.py` alarms are
  unchanged, because chain8's gate consumes them between steps, where a
  shortfall is a real failure.
- Harness improvement: an environment-health contract needs two levels
  ("must hold always" and "must hold between steps"), not one.
- Confidence: verified (timeline.jsonl 23:33-23:59, chain8.log).

### O-14 Owner error: the probe's health definition was wrong for the seed state and ended chain8 falsely   (2026-10-14 00:37, by owner)
- Saw: chain8's gate (the owner's `probe.py`) failed before the baseline
  receipt because the probe expected as-built BGP session counts in every
  state. After `seed-restore` the fabric is in the documented factory seed
  (leaf01 3, leaf02 2, spine01 1, spine02 4 Established); the devices showed
  exactly that at 00:36. chain8 applied one cure and exited `lab-sick` at
  00:32:56 on a healthy lab. evpn3 and evpn2 were already clean.
- Cause: I gave the loop a single, state-blind definition of "healthy" and it
  adopted it as a gate, as instructed. The proposer's own `seed-restore.sh`
  header documented the seed counts; I had not read it.
- Cost: the last step of chain8 (one receipt) not run, one unneeded bgp restart
  on leaf01, one resume pass spent on a false lab-sick. Caught 4 minutes after
  the chain ended.
- Fix: probe recognises the seed signature and reports `fabric_state`;
  OWNER CORRECTION appended to PROGRESS.md at 00:37 while pass 3 was in
  progress, an exception to my own between-passes rule, taken because the
  proposer was at that moment diagnosing a fault that did not exist.
- Harness improvement: an environment-health contract must be declared per
  expected state (the step says which state it expects), and a new health check
  must be validated against every state the workflow legitimately passes
  through before it is allowed to stop work.
- Eval: EVAL-004-OBS-110 (harness) and EVAL-004-OBS-006 (agent).
- Confidence: verified on the devices and in `/tmp/g3/chain8.log`.

### O-15 With a gate, the recurring VRF fault cost 15 minutes instead of hours   (2026-10-14 01:04, by owner)
- Saw: chain9 (00:43:56) rebuilt the fabric from seed to as-built (P-conv, 10
  min), gate green, then its canary failed on leaf01 with `APPLY-STUCK: kernel
  VRF state did not converge after 3 attempts`; the probe shows CONFIG_DB has
  the VRF, APPL_DB and kernel do not, all units active, swss restart counter 0.
  chain9 wrote `lab-sick-dataplane` and exited at 00:59:09 without recording
  anything. The same fault under chain2-chain7 produced hours of recorded
  garbage and differing receipts.
- Pattern worth testing (inferred from the timeline only): tonight the fault
  appeared on the first VRF add after the fabric was rebuilt (after chain7's
  teardown at 22:55, and after seed to as-built at 00:54), not during steady
  replays at as-built (23:22-00:19, three receipts, no wedge).
- Still unsolved: the root cause of the VRF withdrawal. The loop now fails fast
  on it but cannot yet prevent it.
- Harness improvement: none new; this is O-1's gate paying off. For the lab: a
  canary after every rebuild, before any evidence step, is the cheapest place
  to catch it, and chain9 had exactly that.
- Confidence: verified for the sequence; the "first add after rebuild" pattern
  is inferred from four samples.

### O-16 A grounding gap became a diagnostician instruction to re-record 60 existing proofs   (2026-10-14 01:27, by owner)
- Saw: the critic rejected phase 3 (01:10) for two real gaps (steering receipt
  not clean; a spec.md Known-Limitations edit) and listed 67 `NEEDS-GROUNDING`
  paths for proofs it could not see, because the evidence cited `p3-*` summary
  slices instead of the proof files. All 87 `.cmd`/`.out` pairs were on disk.
  The diagnostician (`gates/GATE3-HINT.md`, CASE: REAL-GAP) then told the
  proposer to "run scripts/proof.sh to record and commit" every listed proof
  (T044-T108) and asserted that existing `scripts/spike/evpn3-*.sh` were "NOT
  FOUND on disk". An accelerator pass started at 01:11:40 to act on it. Several
  of those proofs are destructive (factory clean) and four are clean receipts.
- Should have been caught by: `test -f` on each NEEDS-GROUNDING path before
  calling a criterion's artifact missing. No `grounding_gap` event was emitted.
- Cost: none this time. An owner note at 01:11:58 named the false statements
  and the three real fixes; the accelerator ran the probe first, re-recorded
  nothing (only `p3-spec-kl.txt` changed under proofs/), cured the lab, and got
  `CANARY-OK` at 01:27. Without the note the plausible cost was days and the
  loss of the clean receipts.
- Harness improvement: (a) the critic's feedback builder must split
  "cited file absent on disk" from "file exists but was not cited"; the second
  is a citation fix, never a re-run; (b) the diagnostician must be given, or
  must check, on-disk existence for every path it calls missing; (c) the
  accelerator must refuse to re-record a proof whose `.cmd`/`.out` already
  exist unless the hint names a content defect in it.
- Eval: EVAL-004-OBS-111 (harness), EVAL-004-OBS-007 (agent).
- Confidence: verified (GATE3-FEEDBACK.md, GATE3-HINT.md, run.log, proof
  mtimes, sampled accelerator tool calls).

## O-17 — A proof with an empty section passed two gate attempts; the critic caught it only on the third (14 Oct 04:22)

- Layer: proof scripts + harness (evidence quality).
- Saw: attempt 3 of phase 3 was rejected on T061–T064 only. The stored proofs
  `spike-underlay-v6-<node>.out` (recorded 12 Oct 12:44) have an empty
  "fabric-link v6 addresses" section. Cause: `underlay-node.sh` runs
  `ip -6 -br addr show … | grep -v fe80`; `ip -br` puts the global and the
  link-local address on one line, so the filter drops the whole line. The script
  ends with `|| true` and the proof exits 0. Live read-back at 04:25 shows the
  /127 addresses are configured, so the lab was right and the proof was hollow.
- Why it matters: the proof existed, replayed "clean" (an empty section is
  perfectly deterministic) and was cited for two days. Neither the proposer, the
  replay receipt nor attempts 1–2 of the critic noticed; in those attempts the
  proof contents were outside the critic's byte budget.
- Owner action: note in PROGRESS.md at 04:26 naming the cause and limiting the
  fix to the script line, four re-records and the grounding slice.
- Harness improvement: (a) `proof.sh` should fail a recording when a
  `===== section =====` header is followed by no output (or let the script
  declare a minimum line count per section); (b) drop `|| true` after filters in
  proof bodies; (c) a clean replay must not be read as "proof is meaningful" —
  determinism and content are separate checks.
- Eval: EVAL-004-OBS-112 (harness), EVAL-004-OBS-008 (agent).
- Confidence: verified (stored .out files, script source, live read-back on leaf01).

## O-18 — Critic verdicts are not monotonic: a defect raised in attempt 2 vanished in attempt 3 and returned in attempt 4 (14 Oct 04:41)

- Layer: harness (critic grounding / verdict memory).
- Saw: attempt 2 rejected T082/T089 (recipe doc sections). Attempt 3 rejected
  only T061–T064. Attempt 4 rejects T056–T060, T081, T082, T101, T116. The docs
  (`docs/SRV6_SERVICE_RECIPE.md`, `data-model.md`) were last modified 12 Oct, so
  the T082 defect ("Status: empty — no attempt recorded." above a filled
  section) was present through all four attempts; the v4 underlay slice was
  byte-identical between attempts 3 and 4. The proposer also never fixed the doc
  after attempt 2.
- Why it matters: each attempt exposes a different subset of real gaps, so the
  loop converges one subset per attempt (20 min to 2.5 h each) and "attempt N
  rejected fewer items" is not evidence of progress. The proposer reads the
  shorter list as "everything else accepted" — so did the owner (my 04:26 note
  said so, wrongly).
- Harness improvement: (a) carry forward unresolved criteria: a criterion
  rejected in attempt N stays open until the critic explicitly marks it met;
  (b) the critic must emit a per-criterion table (met / unmet / not examined)
  rather than a list of unmet only; (c) small proof outputs should be grounded
  whole, not as "decisive lines".
- Eval: EVAL-004-OBS-113 (harness).
- Confidence: verified (feedback of attempts 2–4, file mtimes); the cause
  (byte budget vs. critic sampling) is inferred.
