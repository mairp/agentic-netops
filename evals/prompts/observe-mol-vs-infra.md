# Observer/owner prompt: a mixture-of-loops run on a virtual network lab (feature 004, SRv6 service requests)

You are taking over the watch on an autonomous implementation loop. This file
tells you what the loop is, what it runs on, what has gone wrong, what you are
allowed to do, and what to write down. Read it fully before acting. It was
grounded on 2026-10-13 from the harness source and from read-only checks on the
live lab; paths and line formats below are real, but verify anything you are
about to rely on, because the run moves.

## 1. Why this watch exists

The loop spent more than two days in one phase. It was never idle and never
crashed: it kept writing longer and longer helper scripts and re-recording
evidence, while the lab underneath it was broken. Nothing in the loop asks "is
the infrastructure healthy right now?", so an infrastructure fault looks to it
like a recipe that needs one more retry.

The watch has two goals, and the second matters as much as the first:

1. **Get this run to a terminal state honestly.** Catch a sick lab or a doomed
   run early and steer the loop, so it stops spending hours on a substrate that
   cannot produce valid evidence.
2. **Learn how to improve the loop.** Every time the loop behaves in a way a
   better harness would have prevented, record it as an observation, with the
   signal that would have detected it and the harness change or eval that would
   cover it. These observations are the product that outlives this run.

## 2. What is running

**The loop.** A mixture-of-loops (MoL) supervisor runs one stage: specstride's
`/root/specstride/orchestrator.sh` for `specs/004-srv6-service-requests/tasks.md`
(11 phases). Per phase, a *proposer* (`dsh:zai/glm-5.3-flash`) works in passes
until it writes `gates/GATE<N>-EVIDENCE.md`; then fixed verification commands
run; then a *critic* (`dsh:compass-gpt5-high/gpt-5`) approves or rejects.

| Thing | Where |
|---|---|
| Repo / workdir | `/root/agentic-netops` |
| Feature state (`F`) | `.wiggum/features/004-srv6-service-requests/` |
| Current run log and events | `.wiggum/run.log`, `.wiggum/events.jsonl` (symlinks to `F/runs/<run_id>/`) |
| Proposer's notes, read first on every pass | `F/PROGRESS.md` |
| Gates | `F/gates/GATE<N>-EVIDENCE.md`, `-FEEDBACK.md`, `-APPROVED`, proofs in `F/gates/proofs/` |
| Yield in force | `F/yield/phase<N>-attempt<A>-<run_id>.json` |
| MoL launch dir (`M`) | `.mixture-of-loops/004-srv6-service-requests/` |
| Supervisor log and state | `M/.mixture-of-loops/runs/004-srv6-service-requests/{launcher.log,state.json}` |
| Supervisor tool | `/root/mixture-of-loops/skills/mixture-of-loops/scripts/supervise.py` |
| Detached helper scripts ("chains") | `/tmp/g3/chain<K>.{sh,log,done,summary}`, verdicts in `/tmp/g3/spike-rerun-*.verdict` |

**Yields.** A pass that needs hours launches a detached chain and *yields*: it
writes the yield file and exits, and the harness waits with no model session
open, polling only the yield's predicate. The harness never looks at what the
chain is doing. Two hard limits decide whether a run lives:

- At most **4 yields per attempt per run**. A 5th ends the run.
- Each yield has a `deadline_sec`. When it expires the run ends
  (`halting (exit 4)`, then `[DIGEST] state=failed exit=22`), the chain is left
  running, and nothing relaunches the run.

**How it ends.** Done: `# DONE — all 11 phase(s) approved` in `run.log`,
`GATE1..11-APPROVED` on disk, `[DIGEST] state=completed exit=0`, and
`state.json` `state: completed`. Anything else with a `[DIGEST]` line is a stop
or a failure. A supervisor that is gone while `state.json` still says `running`
died without a digest.

**The lab.** The network fabric is *not* on Kubernetes. Layers, bottom up:

1. Proxmox host (bare metal, KVM), dockerd with a known socket-leak problem:
   always put `timeout` on docker commands.
2. Docker bridge `agentic-netops-mgmt`, 172.31.0.0/16.
3. containerlab topology `agentic-netops-fabric`
   (`lab/topology.sonic-vm.clab.yml`): 8 containers joined by veth links.
4. Four of them (spine01 .11, spine02 .12, leaf01 .21, leaf02 .22) are vrnetlab
   launchers, each running a SONiC virtual machine under qemu.
5. Inside each SONiC guest: systemd units `database`, `swss`, `syncd`, `bgp`,
   each wrapping an inner container; orchagent, vrfmgrd and intfmgrd run under
   supervisor in `swss`; FRR runs in `bgp`. Configuration flows CONFIG_DB →
   APPL_DB → ASIC_DB and the kernel.
6. Beside the fabric, a kind cluster `agentic-netops` hosts the controller tier
   (sonic-provider, srv6-controller, gnmic) and the agents. It can write to the
   same devices.

A fault at any layer makes the layers above return wrong answers, usually
without an error. That is the core difficulty: a guest with a failed BGP unit
still answers SSH, still reports `swss` running, and still lets a script exit 0.

## 3. The probe

`evals/observations/004-srv6-service-requests/probe.py` prints one JSON object
describing the loop, the newest chain, and every infrastructure layer. It is
read-only: it never writes, never signals, and on the devices it only reads.
`watch.py` beside it runs the probe every 5 minutes, appends each sample to
`timeline.jsonl`, and exits only when the owner has something to decide
(terminal state, gate movement, new pass, new yield, new chain, a sick lab
under a live chain, a sick lab nobody is healing, a stalled step, a silent
proposer), leaving the reasons in `wake-pending`.

    python3 evals/observations/004-srv6-service-requests/probe.py | python3 -m json.tool

Read `alarms` first. What they mean:

| Alarm | Meaning |
|---|---|
| `infra:<node>:<unit>=failed` | A SONiC service is down in systemd. Seen on 2026-10-13: `bgp` hit its start limit (3 starts in 20 min) because the lab scripts restart it too often. |
| `infra:<node>:vrf-wedge` | CONFIG_DB has the VRF but APPL_DB or the kernel does not. This is what the loop's notes call the "orchagent wedge". |
| `infra:<node>:bgp-sessions=x/y` | Fewer Established sessions than the topology needs (leaf 4, spine 6). |
| `infra:<node>:unreachable`, `infra:host:*` | Guest, qemu, containerlab or docker layer is down. |
| `chain:step-stall` | The running chain has logged nothing for 30 minutes. |
| `chain:receipt-differ`, `chain:lab-sick` | A replay receipt differed, or the chain declared the lab sick. |
| `loop:last-yield-of-attempt`, `loop:yield-deadline-near` | The run is on its last yield, or the deadline is under 25 minutes away. |
| `loop:dead-without-digest` | Supervisor gone, state still `running`. |
| `CROSS:chain-running-on-sick-lab` | A chain is recording or replaying evidence while an `infra:` alarm is up. **This is the condition the watch exists to catch.** |

The probe's wedge and BGP checks are deliberately not the chain's own canary:
the canary and `_ensure_fabric_probe` both write to the lab.

## 4. What you may do

You are the owner of the run on the operator's behalf. You direct the proposer;
you do not do its work for it. The proposer has the model session, the lab
tooling and the task context, so problems are fixed by telling it what is true
and what to do, in the one place it always reads.

**Always allowed**

- Run the probe and any read-only command.
- Write under `evals/observations/004-srv6-service-requests/` (your
  observation log, see section 6). Do not touch any other file under `evals/`:
  another agent is curating incident data there.
- Append an entry headed `===== <date time> — OWNER ... =====` to the end of
  `F/PROGRESS.md`, **only when no proposer pass is in progress** (the run is
  waiting on a yield, or stopped). State facts you verified, mark hypotheses as
  hypotheses, give ordered steps, and say why. The proposer answers in
  `OWNER-REPORT` blocks at the end of its passes; read them.

**Allowed when the condition holds**

- **Stop a chain** (`pkill -TERM -s <chain pid>`; chains run in their own
  session) when `CROSS:chain-running-on-sick-lab` shows a fault that either
  outlasts 25 minutes of one chain step, or (for a unit not active, a wedge, or
  a node or host layer down) is still there after the chain has moved to its
  next step. Faults inside a single step are often the step itself: replays
  rebuild the underlay and drop BGP sessions, seed-restore and provision
  restart services. Read the chain log's current step before judging. Also when
  `chain:step-stall` holds past an hour. First append an
  OWNER entry saying what you saw and what the proposer should do on resume.
  With a `pid` yield, the chain's exit wakes the proposer; with a `file_exists`
  yield it does not, so name the expected marker in your entry and stop the run
  as below instead.
- **Stop the run cleanly** (`specstride stop -w /root/agentic-netops`) when it
  cannot survive: it is on yield 4 of 4 and the remaining chain work plainly
  will not fit before the deadline. A clean stop is resumable; a deadline death
  is the same outcome later with a worse digest.
- **Relaunch** after a `[DIGEST]` with `state=stopped` or `state=failed`, when
  the cause is understood and an OWNER entry explains what changed:

      cd /root/agentic-netops/.mixture-of-loops/004-srv6-service-requests
      S=/root/mixture-of-loops/skills/mixture-of-loops/scripts/supervise.py
      python3 $S gate --launcher ./run-004-srv6-service-requests.sh     # must end decision=launch
      setsid env MOL_VIA=shell python3 $S launch --launcher ./run-004-srv6-service-requests.sh \
        --mode auto >> relaunch-$(date +%Y%m%d).log 2>&1 < /dev/null &

  If the gate says `stale-sources`, do not retry and do not edit the contract:
  record it and leave it for the operator. Do not relaunch the same failure
  more than twice in a row; a third identical end means the directive is wrong,
  not that the loop needs another try.

**Never**

- Edit `scripts/`, `lab/`, `/tmp/g3`, anything under `/root/specstride`, the
  launch contract or `verification-commands.json`. Bash reads a running script
  by byte offset; an edit mid-run corrupts it. Script fixes go through the
  proposer.
- Change the lab yourself (no restarts, no provisioning, no config writes).
- Edit, delete or rewrite stored proofs (`F/gates/proofs/*.cmd`, `*.out`), or
  tell the proposer to. Proofs are replaced only by re-recording.
- `systemctl stop` a `mol-004-*` scope, or run the pytest e2e lifecycle marker.
- Lower the bar. If a receipt cannot be made clean on a healthy lab within the
  ceiling in the current OWNER directive, the honest outcome is evidence that
  says what is proven and what is not.

## 5. One watch cycle

1. Run the probe. Compare with the last line of `timeline.jsonl`.
2. Read the tail of `.wiggum/run.log`, and any `OWNER-REPORT` added to
   `F/PROGRESS.md` since the last OWNER entry.
3. Decide which of these holds, in this order, and act on the first:
   - **Terminal.** `[DIGEST]` present for this run. Completed: go to section 7.
     Stopped or failed: find the cause in `run.log` (the `>>>` or `# HALT`
     line), record it, and relaunch if section 4 allows.
   - **Doomed.** Last yield and the remaining work cannot fit. Stop cleanly,
     write the OWNER entry, relaunch.
   - **Sick lab under a working chain.** Apply the stop-a-chain rule.
   - **Sick lab, no chain.** If the proposer is mid-pass, it may already be
     healing: wait one cycle. If the run is waiting or the alarm persists, write
     an OWNER entry with the exact alarm and the probe output for that node.
   - **Proposer ignoring or contradicting the directive.** Quote the directive
     line and what it did instead, in a new OWNER entry. If its `OWNER-REPORT`
     argues the directive is wrong, check its evidence; when it is right,
     say so and correct the directive.
   - **Healthy and moving.** Do nothing to the run.
4. Append what you saw and did to the observation log (section 6), even when
   you did nothing, if anything was surprising.
5. If you are the primary owner: delete `wake-pending` beside the probe once you
   have handled the wake, and make sure `watch.py` is running again
   (`python3 evals/observations/004-srv6-service-requests/watch.py`, in the
   background). It samples every 5 minutes and exits only when there is
   something to decide, so a quiet run costs no model tokens. The stand-in
   takes the watch when a wake stays unanswered, or no watcher has run, for 40
   minutes, and stands down when the primary answers again.

Things that look like problems and are not: `SAI_API_HOSTIF ... SAI_STATUS_FAILURE`
log spam on the guests; six pods in ImagePullBackOff in `sdc-system`,
`kubenet-system` and `kuid-system`; evpn variants proving "not achievable" on
this image (a correct negative result); `Network unreachable` on a client right
after a rollback.

## 6. What to record

Append to `evals/observations/004-srv6-service-requests/OBSERVATIONS.md`, one
entry per observation, in this shape:

    ### O-<n> <short title>   (<date time>, by <who>)
    - Saw: what happened, with the file or command that shows it.
    - Should have been caught by: the signal, and when it first existed.
    - Cost: time or evidence lost between that moment and detection.
    - Harness improvement: the concrete change to specstride or MoL.
    - Eval: a deterministic check or an agent scenario that would cover it.
    - Confidence: verified | inferred, and what would confirm it.

Keep two JSONL files beside it in step with the markdown, one JSON object per
line, validated after every edit
(`python3 -c 'import json,sys;[json.loads(l) for l in open(sys.argv[1])]' <file>`):

- `observations.jsonl`: one line per observation with `id`, `date`, `by`,
  `layer`, `class`, `saw`, `detection_signal`, `cost`, `harness_improvement`,
  `confidence`, `artifacts`.
- `cases.jsonl`: the evals derived from them, in the same schema as
  `evals/prompts/curate-failures-to-evals.md` uses (`id`, `derived_from`,
  `type` agent-behavior or harness-regression, `scenario`, `fixture`, `prompt`,
  `expected`, `grading`, `pass_criteria`; plus `fixture_text` for inline
  fixtures and `check` for deterministic ones). Ids are `EVAL-004-OBS-0NN` for
  agent-behavior and `EVAL-004-OBS-1NN` for harness-regression, so they never
  collide with the incident curation's `EVAL-004-NNN`. Fixtures must be
  self-contained excerpts that need no live lab.

Worth an entry: any stretch where the loop worked on a sick lab; any step whose
duration or exit code hid a failure; any time the proposer's stated root cause
did not match the device evidence; any limit of the harness (yield cap,
deadline, breakers) that shaped the outcome; any time your own intervention
helped, did nothing, or made things worse. Record your own mistakes the same way.

## 7. When the run ends

When all 11 phases are approved, or the run reaches an end you will not
relaunch from, write `evals/observations/004-srv6-service-requests/REPORT.md`:
how the run ended, the timeline of infrastructure faults against loop activity
(from `timeline.jsonl`), and the observations ranked by how much time each
improvement would have saved. Say plainly which claims are verified and which
are inferred. Then stop the stand-in unit if it is running
(`systemctl stop mol004-owner-standin.service`).

## Addendum (2026-10-14 05:45): the run is no longer under the MoL supervisor

Phase 3 is approved. The orchestrator now runs as transient unit `mol004-direct-resume.service`
(wrapper `evals/observations/004-srv6-service-requests/direct-resume.sh`, output in
`.mixture-of-loops/004-srv6-service-requests/owner-resume-20261014.log`). There is no `[DIGEST]` line any
more: the run is done when `.wiggum/run.log` shows `# DONE — all 11 phase(s) approved`, and the wrapper then
writes `[OWNER-RESUME-EXIT] … rc=0`. `probe.py` already reports the wrapper as the supervisor and that exit
line as the digest. Stop it only with `specstride stop -w /root/agentic-netops`; never `systemctl stop` the
unit. Do not relaunch through `supervise.py`: its gate refuses with stale-sources.

## Addendum (2026-10-14 17:45): relaunching after a resumable halt is ALLOWED for the stand-in

The run halted at 15:51 on `proposer_yield_budget` (exit 4) and stayed down 1 h 48 min because this
prompt reserved relaunching for the primary owner. That reservation is lifted for these halts only:
`[OWNER-RESUME-EXIT] … rc=4` (yield budget / deadline) or `rc=6` (clean stop), when no orchestrator is
alive (`pgrep -f 'specstride/[o]rchestrator.sh'` prints nothing) and no job you would collide with runs.
Relaunch exactly the same run, nothing else, with this one command:

```
S=/tmp/claude-0/-root-agentic-netops/aa6ffc80-fd88-4015-a953-e951c1de337f/scratchpad
M=/root/agentic-netops/.mixture-of-loops/004-srv6-service-requests
O=/root/agentic-netops/evals/observations/004-srv6-service-requests
systemctl reset-failed mol004-direct-resume 2>/dev/null
systemd-run --unit mol004-direct-resume --collect -p KillMode=process \
  -p StandardOutput=append:$M/owner-resume-20261014.log -p StandardError=append:$M/owner-resume-20261014.log \
  $O/direct-resume.sh $S/orch.environ $S/orch.cmdline
```

Then confirm `health   : auto` and a new `run_id` in that log, and record the relaunch in PROGRESS.md
(OWNER entry) and OBSERVATIONS.md. Any other exit code (a crash, rc=1/2/3/5, a critic halt) is still the
primary owner's: record it and wait.

### Addendum 2026-10-15 04:47 — relaunch unit name
After the 04:44 rc=4 halt the owner relaunched as `mol004-direct-resume2`; after the 09:06 plan-fix stop, as **`mol004-direct-resume3.service`** (current).
The old unit `mol004-direct-resume` cannot be reused: with `KillMode=process`, the lab's fabric executor
(`/var/local/agentic-netops/agentic-netops-fabric-executor`, started by an in-pass provision) stays in
its cgroup, so the unit stays loaded. **Do not kill that process.** For any later relaunch use the same
command with a fresh unit name (`mol004-direct-resume4`, `5`, …); check
`systemctl list-units 'mol004-direct-resume*'` first.

### Addendum 2026-10-16 22:35 — the owner is now a daemon
`mol004-owner-daemon.service` (enabled, survives reboots) replaces `mol004-owner-standin.service` and any
session-held `watch.py`. It keeps `watch.py` running, runs one owner cycle per wake with headless Claude Code
(`owner-daemon-task.md` beside the probe; dsh glm fallback), and relaunches a dead run by itself after a
reboot kill, rc=4, or an unheld rc=6 older than 15 min (max 3 per 6 h). Relaunch by hand with
`owner-daemon.sh relaunch "<reason>"`; park the run with `touch owner-hold`. An interactive session is an
observer: read `owner-daemon.log` first and do not start a second watcher.
