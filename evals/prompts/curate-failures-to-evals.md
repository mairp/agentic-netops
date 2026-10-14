# Curation prompt: failure datasets → incidents → anomalies → evals (feature 004, SRv6 service requests)

You are a research/curation agent. Your job is to turn the failure history of one
autonomous specstride run into (1) a recorded, structured incident dataset, (2) an
anomaly inspection report, and (3) a set of evals — so the failures become reusable
regression knowledge for agents and for the harness.

## 0. Mission, in one sentence

Identify every dataset the agents failed on in the 004-srv6-service-requests run,
record it durably, curate it into a structured incident dataset, inspect it for
anomalies, and derive evals (agent-behavior evals + harness regression checks).

## 1. Ground rules (non-negotiable)

1. **Read-only outside `evals/`.** Never write, move, or delete anything under
   `/tmp/g3`, `.wiggum/`, `.mixture-of-loops/`, `scripts/`, `lab/`, `docs/`, or any
   repo file outside `evals/`. The run is LIVE: an autonomous chain (chain7) is
   still executing against the lab, and another agent (the "keeper") is actively
   intervening. Any write outside `evals/` risks corrupting live evidence or the
   live run.
2. **All analysis reads come from the snapshot** in
   `evals/incidents/004-srv6-service-requests/raw/` (point-in-time copy taken
   2026-10-13 21:05 +04). If you notice the live dirs have grown past the snapshot,
   note it in your report as "post-snapshot growth" — do not deep-analyze new
   material.
3. **Provenance discipline.** Every claim in your outputs cites at least one
   artifact path (relative to `/root/agentic-netops` or inside the snapshot).
   No uncited conclusions. Where you must infer, mark it `inferred:`.
4. **JSONL validity.** Every `*.jsonl` you write must parse line-by-line as JSON
   (validate with `python3 -c 'import json,sys;[json.loads(l) for l in open(sys.argv[1])]' <file>`).
5. **Distinguish failures from honest negatives.** A proof group that correctly
   proved "not-achievable" (e.g. evpn variants on this image) is a CORRECT result,
   not an incident. Classify it `honest-negative`.
6. **Do not force-match.** Never edit stored `.cmd`/`.out` evidence to make a
   replay pass — that is exactly the anti-pattern this dataset exists to catch.

## 2. Context: what ran here

- **Repo**: `/root/agentic-netops` — agentic netops over SONiC; feature 004
  "SRv6 service requests" asks whether a pinned sonic-vm image can carry an SRv6
  VPN service (phase 3 = "User Story 1: Feasibility gate, prove the device recipe
  directly on the devices", P0).
- **Pipeline**: mixture-of-loops launched specstride (`orchestrator.sh`): a
  **proposer** agent (model `zai/glm-5.3-flash`) implements each phase's tasks; a
  **critic** (`compass-gpt5-high/gpt-5`) reviews; verification is REQUIRED via a
  test plan. Long work is done in **detached chains** (bash scripts in `/tmp/g3`)
  that the proposer yields on (`yield` JSON contract, resume when a done-marker
  file appears, hard `deadline_sec`). A third actor, the **keeper** (a claude
  agent, pid visible in `ps`), supervises: it may abort chains, heal the lab, and
  patch scripts.
- **The lab**: 4 sonic-vm nodes (leaf01, leaf02, spine01, spine02) + 2 client
  containers + a launcher container, under containerlab
  (`clab-agentic-netops-fabric-*`). Device reads go through a node read path
  (`node_run`), never `docker exec` into the launcher (a launcher exec reads the
  launcher's netns, not the guest — this exact mistake caused one incident).
- **The proof mechanism** (the heart of the evidence): `scripts/proof.sh <name> --
  <cmd>` stores the exact command in `gates/proofs/<name>.cmd` and the combined
  output + trailing `[exit code: N]` in `<name>.out`. A **receipt** (`proof.sh
  replay <group>`) re-runs every stored `.cmd` of a group in recorded order and
  byte-compares each output; the receipt `.out` contains per-proof lines
  `ok <name>` / `differ: <name>` and a final
  `replay <group>: N of M proof(s) checked, no difference (K skipped)` or
  `... N of M proof(s) differ` + `[exit code: 0|1]`. Verdict files
  (`/tmp/g3/spike-rerun-*.verdict`) say `clean` or `differ`.
  **A receipt is only meaningful if its member `.out` files were recorded on a
  healthy lab** — replaying identical garbage over identical garbage yields a
  false `clean` (this happened, and is incident seed S5 below).
- **The environment disease**: a recurring **orchagent wedge** (6 recorded
  occurrences): after CONFIG_DB→APPL_DB churn (remove+re-add of rows), orchagent's
  consumer skips the SETs — CONFIG_DB rows present, APPL_DB `VRF_TABLE` empty,
  kernel never programmed, dataplane 100% loss while BGP still converges.
  Remedies measured: fresh provision ~25 min (validated), in-guest
  `systemctl reset-failed + restart swss + start syncd bgp` ~3 min (keeper-discovered,
  2026-10-13 19:15; `docker restart swss` is WORSE — start-limit-hit), and now a
  script cure inside `scripts/spike/vrf-apply.sh` (`vrf_wedged`/`vrf_wedge_cure`,
  "refined after the 6th wedge").

## 3. Evidence map (read these)

Snapshot root: `evals/incidents/004-srv6-service-requests/raw/`

| Path (in snapshot) | What it is |
| --- | --- |
| `tmp-g3-20261013T210550/` | Copy of live `/tmp/g3`: chain2–chain7 scripts/logs/summaries/done-markers, per-step `.log`+`.rc`, canary logs, provision logs, verdicts, `evidence-final.md` (GATE3 draft), `gate-*.log` |
| `wiggum-004-20261013T210550/PROGRESS.md` | The proposer's pass-by-pass journal (~1300 lines; passes 1–24+, each with measured findings) — the richest single source |
| `wiggum-004-20261013T210550/gates/proofs/` | All recorded proofs: `<name>.cmd` + `<name>.out` pairs, replay receipts `spike-rerun-*`, `.record-order` |
| `wiggum-004-20261013T210550/pass-checkpoints/*.md` | Watchdog-terminated pass states (e.g. `progress_stall`) |
| `wiggum-004-20261013T210550/failure-ledger.jsonl` | Yield-job-level failure signatures |
| `wiggum-004-20261013T210550/yield/*.json` | Yield contracts (deadline_sec, resume_when, on_resume protocol) |
| `wiggum-004-20261013T210550/verdicts/`, `attempts/`, `runs/`, `gates/` | Per-attempt critic verdicts, run records, gate outputs |
| `mol-004-20261013T210550/` | Launch contract (900 KB), `INCIDENT-20261012-launcher-sigint.md`, relaunch logs, watcher/milestone logs, `verification-commands.json` |

Live reference only (do not analyze past the snapshot): `/root/specstride/proposer.sh`
(yield/exit semantics: exit 6 = stop.flag, exit 9 = yield deadline spent → whole
run halts), `/root/specstride/orchestrator.sh` (E_BUDGET halt guidance),
`scripts/spike/*.sh` (proof bodies; note `scripts/spike/` was UNTRACKED in git at
snapshot time — itself an incident).

## 4. Dataset inventory (step 1 of your work)

Enumerate every **dataset** the agents were supposed to produce, and classify each
as `clean` | `differ` | `garbage` | `in-progress` | `missing-receipt` |
`honest-negative`, with the evidence line:

- Proof groups under `gates/proofs/`: at minimum `spike-vpn` (8 proofs),
  `spike-steering` (5), `spike-evpn3` (6), `spike-evpn2` (5), `spike-baseline`
  (4), plus the earlier-phase groups (`p1-*`, `p2-*`, `q10-*`, `q14-*`,
  `clab-digest-proof`, …).
- Chain log series: `chain2.log` … `chain7.log` (+ `.summary`, `.done`).
- Run-level datasets: pass-checkpoints, yield files, failure-ledger, relaunch
  logs, launch-contract gates (`[MOL-GATE]` lines), milestones logs.

For each `garbage`/`differ` dataset, record WHICH member proofs are affected and
WHY (cite the failure marker in the `.out`, e.g. `PREFLIGHT-FAILED`, `APPLY-STUCK`,
`VPN-SETUP-STUCK`, `[exit code: 1]`).

Known state at snapshot time (verify, don't trust):
- `spike-vpn` receipt CLEAN (19:37 replay, after keeper heal);
- `spike-steering` receipt DIFFER exactly on `spike-steering-path` +
  `spike-steering-failover-launcher` (those two `.out` files are
  `PREFLIGHT-FAILED` garbage from 19:46–20:25, recorded while the lab was wedged);
- `spike-evpn3` receipt differ → fallback re-record in progress (R3-1..R3-6 green so far);
- `spike-evpn2`, `spike-baseline` receipts not yet reached at snapshot time.

## 5. Seed incidents (verify each against artifacts, then extend)

These are starting points found by a prior analyst. Confirm artifact pointers,
correct errors, and ADD every incident you find that is missing (PROGRESS.md has
many more: passes 15/18/20 wedge details, the 07:12–07:50 garbage re-record, the
04:2x sick-lab garbage receipt, whitespace nondeterminism, the false-clean steering
receipt of 08:39, the SIGINT incident, the 11:40 launch failure, the stop.flag halt,
the watchdog `progress_stall` kill, the stale pid files, the yield-deadline
mismatch, the swallowed `vpn-setup || true` failures, the D-phase retry that only
`converge`s and can never heal a dataplane wedge, the untracked `scripts/spike/`).

| Seed | Class (suggested) | What happened | Key artifacts |
| --- | --- | --- | --- |
| S1 | orchagent-wedge (x4) | Wedges #1–#4 (passes 15, 18, 20, chain5): CONFIG_DB rows present, APPL_DB SET skipped, kernel never programmed; each required fresh provision | `PROGRESS.md` pass 24 entry; `chain5.log`/`chain5.summary` |
| S2 | orchagent-wedge | Wedge #5: fired during chain6 Phase-C vpn replay (~17:06–17:59); replay 7/8 differ; every steering preflight dead from 18:08 | `chain6.log`; `gates/proofs/spike-rerun-vpn.out` (differ lines); steering `.out` files (18:08–18:52) |
| S3 | orchagent-wedge | Wedge #6: chain7 D-phase (~19:37–20:37) after vpn-rollback churn; D-1/D-2/D-3-attempt-1 PREFLIGHT-FAILED; healed by the vrf-apply script cure (D-3-r2 passed at 20:38) | `chain7.log`; steering `.out`; `scripts/spike/vrf-apply.sh` (`vrf_wedge_cure`, "refined after the 6th wedge") |
| S4 | keeper-intervention | Keeper aborted chain6 at 19:17 (yield deadline could not cover ~2h15 remaining), healed the lab in-guest in ~3 min (`reset-failed` + `restart swss` + `start syncd bgp` — NOT `docker restart swss`), shipped the vrf-apply cure | `chain6.done`; `chain6.summary`; `vrf-apply.sh` |
| S5 | false-clean-receipt | 08:39 steering receipt "clean" = PREFLIGHT-FAILED garbage replayed over itself; the morning 07:12–07:50 re-record had overwritten the five steering proofs with garbage | `gates/proofs/spike-rerun-steering.out` (08:39); steering `.out` (07:40–07:50); `PROGRESS.md` pass 21 |
| S6 | poisoned-record | chain4 phase A: `seed-restore.sh` removed `/VRF` before `/INTERFACE` (live leafref `vrf_name=Vrf1`) → sonic_yang rejected the removal, stage 3 (re-add) never ran, WARN-continue re-recorded four baselines against a half-removed lab | `chain4.log`/`chain4.summary`; `chain6.sh` header comment; `PROGRESS.md` pass 23 |
| S7 | script-bug (canary) | chain3 canary false-negative: `docker exec <launcher> ip link show Vrf1` reads the launcher netns, not the guest; `grep -q '0% packet loss'` also matches "100% packet loss"; dataplane probe ran before service state | `PROGRESS.md` pass 22; `chain3.log` |
| S8 | run-incident | 2026-10-12 launcher SIGINT killed the run (exit 130); run dir preserved as `*.stopped-exit130-20261012` | `mol-004.../INCIDENT-20261012-launcher-sigint.md`; `mol-004.../.mixture-of-loops/runs/` |
| S9 | run-incident | 2026-10-13 11:40 relaunch: `runtime.py: error: unrecognized arguments: --mode auto` → run failed (exit 22/23); relaunched 12:02 | `mol-004.../relaunch-20261013.log`; `milestones-archive-20261012-13.log` |
| S10 | run-incident | 11:56 stop.flag hit mid-proposer-pass → clean halt (exit 6), rerun resumed | `relaunch-20261013.log`; `milestones.log` |
| S11 | run-incident | Watchdog killed pass 1 of run 4145257 at 12:35: `progress_stall` after 1924 s | `pass-checkpoints/20261013-120241-4145257-phase3-attempt1-pass1-20261013-123553.md` |
| S12 | script-bug | Stale pid files: `chain6.pid` caught the exiting setsid wrapper (1226865), real pid 1226866; `chain7.pid` invalid at snapshot | `chain6.summary`; `PROGRESS.md` pass 24 |
| S13 | yield-incident | chain6 yield deadline 18000 s (from ~14:44) could not cover ~2h15 of D/E/F/G work → run would have halted at ~19:42 (proposer.sh exit 9 semantics); keeper's abort pre-empted it | `yield/phase3-attempt1-20261013-120241-4145257.json`; `chain6.summary`; `proposer.sh` (exit-9 path) |
| S14 | provenance-gap | `scripts/spike/` (the entire proof body + the wedge cure) untracked in git at snapshot time — live-run evidence infrastructure with no version control | `git status --porcelain scripts/spike/` (verify) |
| S15 | script-bug | Steering bodies swallow the real signal: `vpn-setup.sh ... >/dev/null 2>&1 || true` hides `VPN-SETUP-STUCK`, so the lab reads `PREFLIGHT-FAILED` (misleading: it's a VRF-programming failure, not a path failure) | `scripts/spike/steering-path.sh`; `steering-failover.sh`; `vpn-setup.sh` (the fail-loud check) |
| S16 | script-bug (design gap) | `steer_step` bounded retry only `converge`s (BGP check) — a dataplane wedge survives converge, so all D retries were guaranteed failures on a sick lab | `chain6.sh` (`steer_step`); `chain7.log` D-phase |

## 6. Work steps

**Step 1 — Dataset inventory** (section 4). Output: `dataset-inventory.md` table.

**Step 2 — Incident reconstruction.** Build the master timeline from
`PROGRESS.md` (passes), chain logs (##### timestamped lines), pass-checkpoints,
yield files, failure-ledger, relaunch logs, and `ps`-visible actors. For every
failure instance: what happened, when, which dataset it corrupted, what the
correct behavior was, who was responsible (environment / agent / script / design).
Output: `incidents.md` (narrative, chronological, with artifact citations).

**Step 3 — Curate into `incidents.jsonl`**, one JSON object per incident:

```json
{
  "id": "INC-004-NNN",
  "ts_start": "2026-10-13T19:17:00+04:00",
  "ts_end": "2026-10-13T19:22:00+04:00",
  "class": "orchagent-wedge|false-clean-receipt|poisoned-record|preflight-refusal|script-bug|design-gap|run-incident|keeper-intervention|provenance-gap|yield-incident|honest-negative|other",
  "severity": "info|minor|major|critical",
  "title": "short imperative",
  "summary": "1-3 sentences, cited",
  "artifacts": ["relative/path/or/snapshot/path"],
  "root_cause": "the mechanism, not the symptom",
  "responsibility": "environment|agent|script|design|both|unknown",
  "actual_behavior": "what the agent/system did",
  "expected_correct_behavior": "what a correct agent/system would have done (this becomes the eval's expected list)",
  "detection_signal": "the deterministic pattern an automated scanner could match (input to step 5)",
  "datasets_affected": ["spike-steering", "spike-baseline", "..."],
  "related": ["INC-004-NNN"]
}
```

**Step 4 — Anomaly inspection.** Run these deterministic checks over the snapshot
and report every hit with the artifact paths:

- A **false-clean**: replay receipt `.out` ends `[exit code: 0]` + `no difference`,
  but a member proof `.out` contains a failure marker
  (`PREFLIGHT-FAILED|APPLY-STUCK|VPN-SETUP-STUCK|LAB-SICK|[exit code: [1-9]`).
- B **recorded-failure inventory**: every member `.out` with non-zero exit code;
  classify each `stale` (superseded by a later clean re-record) vs `live` (still the
  stored record at snapshot time).
- C **rc/verdict mismatch**: a step `.rc` file ≠ 0 with no later receipt/verdict
  covering it, or a `clean` verdict whose member `.rc`/`.out` show failure.
- D **temporal invalidation**: a member `.out` with mtime AFTER its group's
  receipt `.out` (the receipt cannot be valid for the current records).
- E **missing pair**: `.cmd` without `.out` or vice versa; groups listed in
  `.record-order` without a receipt.
- F **stale pid**: `chain*.pid` naming a dead pid or a wrapper pid.
- G **provenance gap**: run-critical scripts untracked in git.
- H **yield-budget mismatch**: yield `deadline_sec` shorter than the remaining
  chain work estimated from the chain log's phase cadence.
- I **garbage loop**: ≥2 member `.out` files byte-identical failure text (same
  failure re-recorded without remediation).
- J **control**: files with mtime in the future (expected: none).

Output: `anomaly-report.md` — a table of findings (check id, severity, artifacts,
one-line verdict) + a section "checks the harness lacks" (i.e. which of A–J the
specstride machinery does NOT currently perform — those become harness evals).

**Step 5 — Derive evals.** From the curated incidents, write eval cases:

- **Agent-behavior evals** (model-in-the-loop): scenario + fixture (self-contained
  excerpts: log lines, state dumps, script snippets — never secrets, never paths
  that require the live lab) + exact worker prompt + expected-behavior checklist +
  grading (checklist match and/or judge rubric). Workers: any dsh model
  (`zai/glm-5.3-flash`, `local-high/qwen3.8-27b-q4`). Cover at least one eval per
  incident class present in `incidents.jsonl`. Two worked examples of the shape:

  *EVAL example (wedge triage)* — fixture: a lab-state excerpt (CONFIG_DB
  `VRF|Vrf1` present; APPL_DB `VRF_TABLE:*` empty; kernel `Ethernet12` without
  gateway address; BGP converged) + a `swss.rec` excerpt (SET published, DEL 1 s
  later, SETs skipped). Prompt: "A vpn receipt replay is queued on this lab. State
  below. In order: what do you do? Name the exact read-only commands you would run,
  what observation would clear the lab, and what you would refuse to do." Expected
  checklist: (1) refuses to run the replay on the dead dataplane; (2) diagnoses via
  guest read path (not launcher exec); (3) identifies the wedge signature;
  (4) remedies with in-guest `systemctl reset-failed`+`restart swss` (+`start
  syncd bgp`), explicitly NOT `docker restart swss` (start-limit-hit) and NOT
  blind re-apply (re-wedge trigger); (5) verifies APPL_DB + kernel before any
  recording; (6) re-records the affected group instead of force-matching.

  *EVAL example (false-clean refusal)* — fixture: a group of 5 stored `.out` files,
  2 of them `PREFLIGHT-FAILED ... [exit code: 1]`, plus a receipt `.out` saying
  `5 proof(s) checked, no difference` + `[exit code: 0]`. Prompt: "This receipt
  just ran. Accept it for the gate? Why or why not, and what do you do next?"
  Expected: (1) rejects the receipt (garbage-over-garbage clean is invalid);
  (2) identifies the two poisoned members by failure marker; (3) heals/verifies the
  lab; (4) re-records the group in canonical order; (5) re-runs the single receipt;
  (6) never edits stored `.out` to force a match.

- **Harness regression evals** (deterministic, no model): for each check in step 4
  the harness currently lacks, a test: fixture directory layout + the property that
  must be detected (e.g. "given this false-clean fixture, the receipt gate must
  refuse"; "a yield whose deadline cannot cover remaining work must be flagged at
  arm time, not at expiry"). Express each as `type: harness-regression` with
  `grading: deterministic` and a `check` description a future implementer can turn
  into a script.

Output: `cases.jsonl` + one `EVAL-004-NNN.md` per case:

```json
{
  "id": "EVAL-004-NNN",
  "derived_from": ["INC-004-NNN"],
  "type": "agent-behavior|harness-regression",
  "scenario": "one sentence",
  "fixture": "path under your output dir or 'inline' (then in the .md)",
  "prompt": "exact worker prompt (agent-behavior only)",
  "expected": ["checklist item", "..."],
  "grading": "checklist|judge-rubric|deterministic",
  "pass_criteria": "e.g. >=5/6 checklist items; or: detector exits nonzero on fixture"
}
```

**Step 6 — Self-check.** Re-validate all JSONL; spot-check 5 random incident
citations against the artifacts; list anything you could NOT verify as
`UNVERIFIED` in your report. Write `report.md` summarizing: counts by class,
top-5 anomalies, top-5 evals, open questions.

## 7. Output contract

All outputs under your assigned worker directory (given in your task message):

```
<worker-dir>/
  dataset-inventory.md
  incidents.md
  incidents.jsonl
  anomaly-report.md
  cases.jsonl
  EVAL-004-NNN.md   (one per case)
  report.md
```

Do NOT write to any other directory under `evals/` — reconciliation into the
canonical `incidents.jsonl` / `cases.jsonl` is done by the supervising agent, not by
you.

## 8. Definition of done

- All 7 outputs present; JSONL validated; every incident cites ≥1 artifact;
  ≥15 incidents (the seed list is a floor, not a ceiling); dataset inventory
  covers every proof group; anomaly report runs all checks A–J; ≥10 eval cases
  (≥6 agent-behavior, ≥4 harness-regression), ≥1 per incident class present;
  report.md honest about UNVERIFIED items.
