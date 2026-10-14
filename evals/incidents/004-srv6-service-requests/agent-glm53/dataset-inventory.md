# Dataset inventory — 004-srv6-service-requests (Worker B: agent-glm53)

Snapshot: `evals/incidents/004-srv6-service-requests/raw/` (taken 2026-10-13 21:05 +04).
Path shorthands used below (all relative to `/root/agentic-netops`):

- `RAW`  = `evals/incidents/004-srv6-service-requests/raw`
- `G3`   = `RAW/tmp-g3-20261013T210550` (copy of live `/tmp/g3`)
- `WG`   = `RAW/wiggum-004-20261013T210550` (copy of live `.wiggum/features/004-srv6-service-requests/`)
- `MOL`  = `RAW/mol-004-20261013T210550` (copy of live `.mixture-of-loops/004-srv6-service-requests/` + run logs)
- `PROOF`= `WG/gates/proofs`

Counts verified in-snapshot: **87 `<name>.cmd` + 87 `<name>.out` pairs** (ls counts), `.record-order`
has **88 entries** (1 phantom, see restore-check below), 5 receipt pairs (`spike-rerun-*`), 5
receipts referenced by the yield protocol (`RAW/wiggum-004-20261013T210550/yield/phase3-attempt1-20261013-120241-4145257.json`).

Status vocabulary (per curation prompt §4): `clean` | `differ` | `garbage` | `in-progress` |
`missing-receipt` | `honest-negative`. "Members at snapshot" = the currently stored `.out` bytes
(last writer wins in `.wiggum`).

## 1. Proof groups under `PROOF/` (recorded datasets)

| Group (replay prefix) | Members | Member `.cmd` (bodies) | Last record (mtime) | Status at snapshot | Evidence |
| --- | --- | --- | --- | --- | --- |
| `selftest` | 1 (`selftest`) | `true` | Oct 11 21:55 | clean (proof.sh self-test; re-verified green in later sweeps) | `PROOF/selftest.cmd`, `PROOF/selftest.out`; WG/PROGRESS.md:33-35 |
| `p1` | 4: `p1-setup-unittest`, `p1-image-by-digest`, `p1-network-unaffected`, `p1-agents` | `run-*` wrappers / direct commands | Oct 11–12 (05:43/23:07) | clean, **except `p1-image-by-digest` = honest-negative** (`[exit code: 1]` by design — a throwaway negative probe proving the digest assertion fires), and `p1-network-unaffected.out` lacks the trailing `[exit code: N]` footer (format anomaly, see anomaly report C-3) | `PROOF/p1-image-by-digest.out`; `PROOF/p1-network-unaffected.out` (67 lines, no `[exit code: N]` final line); WG/PROGRESS.md:227-233 |
| `clab-digest-proof` | directory artifact (`clab.yml`), no `.cmd`/`.out` | n/a | Oct 11 22:47 | clean (supporting material for the pin proof, never a replay member) | `PROOF/clab-digest-proof/clab.yml`; `PROOF/p1-image-by-digest.cmd` |
| `q10` | 3: `q10-baseline`, `q10-srv6`, `q10-guard` | `scripts/proofs/run-q10-*.sh` | Oct 12 05:43 | clean (GATE2 attempt-4 restage; replay no-difference) | `PROOF/q10-*.cmd`; WG/PROGRESS.md:242-249 |
| `q14` | 3: `q14-probe`, `q14-gate-vm`, `q14-report-vm` | direct device commands | Oct 12 05:43 | clean (17 pass / 0 fail / 0 skip report; H.Encaps.Red + SID-list executed) | WG/PROGRESS.md:227-230; `MOL/verification-commands.json` |
| `p2` | 3: `p2-configmap-sonic-image`, `p2-pin-assert-live`, `p2-t005-guard` | direct commands | Oct 12 00:24–06:06 | clean (`p2-t005-guard.out` 2.4 KB exit 0) | `PROOF/p2-t005-guard.out`; WG/PROGRESS.md:318-341 |
| `spike-portmap` | 4 (leaf01, leaf02, spine01, spine02) | `spike-portmap-*.cmd` | Oct 12 15:07 | clean (superseded-era records still replay-stable; not in any failing receipt) | `PROOF/spike-portmap-leaf01.out` |
| `spike-underlay-apply` | 4 (all nodes, `--destructive` markers present) | `underlay-apply` per node | Oct 12 15:2x | clean (replay rc=0 verified pass 3) | WG/PROGRESS.md:459-461; `PROOF/spike-underlay-apply-leaf01.destructive` |
| `spike-underlay-v4` | 5 (`spike-underlay-v4` + 4 nodes) | v4 readback per node + aggregate | Oct 12 15:2x | clean (replay rc=0) | WG/PROGRESS.md:459 |
| `spike-underlay-v6` | 5 (same shape as v4) | v6 readback | Oct 12 15:2x | clean | WG/PROGRESS.md:459 |
| `spike-kernel` | 4: `spike-kernel-leaf01`, `spike-kernel-vrf-module`, `spike-kernel-strict-mode`, `spike-kernel-seg6` | kernel prereq probes | Oct 12 16:0x | clean (T066–T068) | WG/PROGRESS.md:471-477 |
| `spike-locator` | 6: `spike-locator-all`, `-leaf01`, `-leaf02`, `-spine01`, `-spine02`, `-reach` | locator write-class + reachability | Oct 12 16:0x–16:1x | clean (T069–T073; includes the documented GCU-wedging-semantics negative findings — honest-negative *content*, exit 0) | WG/PROGRESS.md:478-503 |
| `spike-vrf-apply-leaf01` | 1 | `vrf-apply.sh leaf01` | Oct 12 16:1x | clean (T074 partial: Vrf1 + Ethernet12 + in-VRF reachability, replay green) | WG/PROGRESS.md:508-509; `PROOF/spike-vrf-apply-leaf01.out` (`[exit code: 0]`) |
| `restore-check` | 0 — **phantom**: listed in `.record-order` but NO `.cmd`/`.out` exist | n/a | n/a | missing-receipt (anomaly E-2; a recorded position with no stored evidence) | `PROOF/.record-order` (entry `restore-check`); `ls PROOF \| grep -i restore` → empty |
| `spike-factory` | 4 (all nodes) | factory-clean probe | Oct 12 17:1x | clean (pass-4 era; factory DEVICE_METADATA incident fixed before re-record) | WG/PROGRESS.md:517-527 |
| `spike-identity` | 4 (all nodes) | identity-assert | Oct 12 17:2x | clean | WG/PROGRESS.md:525-530 |
| `spike-baseline` | 4 (all nodes) | `baseline-capture.sh <node>` | **2026-10-13 15:24** (chain6 phase A re-record) | clean members; **group receipt `spike-rerun-baseline` is stale/invalid** (recorded 11:32 against the 11:31 pre-squeeze records; differs on spine02) — see anomaly D-1 | `PROOF/spike-baseline-*.out` mtimes 15:24:43–15:24:56; `PROOF/spike-rerun-baseline.out` (`differ: spike-baseline-spine02`, `[exit code: 1]`); WG/PROGRESS.md:1160-1164 |
| `spike-vpn` | 8: `state-leaf01`, `state-leaf02`, `ping`, `capture`, `readback-leaf01`, `readback-leaf02`, `clients`, `rollback` | `vrf-apply/vpn-ping/vpn-capture/vpn-readback/vpn-clients/vpn-rollback` | **2026-10-13 16:57–17:06** (chain6 RV1–RV8 on healed lab) | **clean** — receipt `spike-rerun-vpn` = 8 checked, no difference, `[exit code: 0]` (19:37 replay; first clean vpn receipt after the wedge cure) | `PROOF/spike-rerun-vpn.out`; G3/chain7.log (C-phase replay CLEAN 19:37); WG/PROGRESS.md:1322-1323 |
| `spike-persistence` | 1 | config reload witness | Oct 12 18:12 | clean (member; not in a failing receipt) | `PROOF/spike-persistence.out` |
| `spike-sid-write` | 1 | SID write-class probe | Oct 12 18:12 | clean | `PROOF/spike-sid-write.out`; WG/PROGRESS.md:1180 |
| `spike-evpn3` | 6: `ping`, `capture`, `kl006`, `rollback`, `state-leaf01`, `state-leaf02` | `evpn3-*.sh` | **2026-10-13 20:58–21:02** (R3-1..R3-6 chain7 fallback, green; R3-6 in flight at snapshot) | **differ → in-progress**: receipt `spike-rerun-evpn3` (20:57) says 3 of 6 differ; fallback re-record running at snapshot (5 of 6 green; 5 of 6 members NEWER than the receipt → receipt invalid, see anomaly D-2) | `PROOF/spike-rerun-evpn3.out`; G3/chain7.log 20:57–21:02; G3/R3-1..R3-6.log/.rc |
| `spike-evpn2` | 5: `state-leaf01`, `state-leaf02`, `ping`, `capture`, `rollback` | `evpn2-*.sh` | Oct 12 16:0x (chain2-era records) | **differ, not yet reached at snapshot**: receipt `spike-rerun-evpn2` (2026-10-13 10:40, chain2) = 2 of 5 differ (`spike-evpn2-ping`, `spike-evpn2-rollback`); chain7's R2 fallback had not started at snapshot | `PROOF/spike-rerun-evpn2.out`; G3/chain2.log 10:40:05; G3/chain7.sh lines 171-175 (`rerecord_evpn2`) |
| `spike-steering` | 5: `path`, `failover-launcher`, `failover-guest-if`, `failover-bgp`, `return` | `steering-path.sh`, `steering-failover.sh <mode>` | 19:59 (path), 20:25 (launcher), 20:38–20:40 (other 3, chain7) | **differ**: receipt `spike-rerun-steering` (20:44) = 2 of 5 differ; `spike-steering-path.out` and `spike-steering-failover-launcher.out` are live **garbage** (`PREFLIGHT-FAILED … [exit code: 1]`, recorded while the lab was wedged in the 6th-wedge window) | `PROOF/spike-steering-path.out`; `PROOF/spike-steering-failover-launcher.out`; `PROOF/spike-rerun-steering.out`; G3/chain7.log 19:46–20:44 |
| `spike-counters` | 1 | counters assertion (gate log shows asserted on both leaves) | Oct 12 | clean (gate log green) | G3/gate-Counters.log; `PROOF/spike-counters.out` |
| `spike-rerun-*` (receipts, T105–T109) | 5 receipts | `scripts/proof.sh replay <group>` | vpn 19:37, steering 20:44, evpn3 20:57, evpn2 10:40, baseline 11:32 | vpn **clean**; steering **differ** (2/5); evpn3 **differ** (3/6, invalid — see above); evpn2 **differ** (2/5, chain2-era); baseline **differ** (1/4, stale) | `PROOF/spike-rerun-{vpn,steering,evpn3,evpn2,baseline}.out`; G3/spike-rerun-*.verdict (`vpn=clean`, `steering=differ`, `evpn3=differ`) |

Group totals: 87 recorded proofs + 5 receipts = 92 `.cmd`/`.out` pairs across 24 replay groups
(incl. `selftest`), 1 phantom record-order entry (`restore-check`), 1 supporting directory
(`clab-digest-proof`). The five groups the yield protocol gates on (T105–T109) are exactly the
five `spike-rerun-*` receipts (WG/yield/phase3-attempt1-20261013-120241-4145257.json).

## 2. Chain log series (G3/)

| Dataset | Files | Status at snapshot | Notes |
| --- | --- | --- | --- |
| chain2 | `chain2.sh/.log/.summary/.done/.pid` | done 10:42:33 (`chain2.done`) | 5 receipts: vpn differ, steering **false clean (08:39)**, evpn3 differ, evpn2 differ, baseline differ; `A-seed=1` (poisoned-seed era), `P-provision=1` tolerated | G3/chain2.log, chain2.summary |
| chain3 | `chain3.sh/.log/.summary/.done` | done **lab-sick** 13:52:42 | canary false-negative (launcher-netns exec + substring grep) → LAB-SICK without recording; `Q1-canary=1`, `Q1-recover=1`, `CANN=1` | G3/chain3.log; WG/PROGRESS.md:1195-1212 |
| chain4 | `chain4.sh/.log/.pid` | killed 14:12, no `.done`/`.summary` | poisoned phase A (garbage baselines 14:08, later overwritten); `chain4.pid=935362` (wrapper) vs kill of 935363 | G3/chain4.log; WG/PROGRESS.md:1227-1234 |
| chain5 | `chain5.sh/.log/.summary/.done` | done **lab-sick** 14:30:42 | real 4th wedge; skipped its own `recover()`; verdicts missing | G3/chain5.log/.summary; WG/PROGRESS.md:1252-1257 |
| chain6 | `chain6.sh/.log/.summary/.done/.pid` | aborted (keeper) 19:17, `chain6.done` present, summary written | H/A/B green; RV1–RV8 green; vpn receipt differ 7/8 (5th wedge); steering D-1..D-5 all rc=1 | G3/chain6.log/.summary; WG/PROGRESS.md:1286-1287 |
| chain7 | `chain7.sh/.log` (no `.pid`, `.done`, `.summary` at snapshot) | **LIVE** (pid 3538140, started 19:33:29; `ps` verified) | C replay clean 19:37; D-1/D-2 failed preflight ×2 each; evpn3 fallback R3-1..R3-6 running (R3-6 in flight at snapshot cut) | G3/chain7.log; WG/yield/phase3-attempt1-20261013-120241-4145257.json (pid 3538140, deadline 14400 s) |
| runner (pass-17 chain) | `runner.log`, `g3-runner.sh` | killed 05:15 | A-dry=1, vpn receipt differ, D-1..D-4 recorded rc=0 **on the sick lab** (garbage-at-record-time) | G3/runner.log; WG/PROGRESS.md:1093-1113 |
| repair | `baseline-repair.sh`, `repair-run.log`, `repair.summary`, `repair.done` | done 11:32 | R-seed=0, R-dry=0, receipt differ (spine02) | G3/repair.summary |
| receipts (pass-16) | `receipts.sh/.log`, `receipts2.log`, `receipts3.log/.rc` | aborted rc=3 ×2, rc=3 | `DIFFERS-ABORT` on spike-rerun-vpn (5/8, 7/8 eras) | G3/receipts.log, receipts3.rc (=3); WG/PROGRESS.md:951-963 |
| step logs | `A-*`, `B-*`, `C-*`, `D-*`, `G-*`, `H*`, `Q*`, `R3-*`, `RV*`, `FG-*`, `H2-*`, `P-provision.*`, `canary*`, `CANN.*`, `gate-*.log` | mixed | per-step `.rc` files; `D-1.log`≡`D-1-r2.log` and `D-2.log`≡`D-2-r2.log` byte-identical (anomaly I) | G3/ listing |

## 3. Run-level datasets

| Dataset | Files | Status |
| --- | --- | --- |
| pass-checkpoints | `WG/pass-checkpoints/*.md` (2 files, 152–153 B) | both "terminated by the specstride watchdog", reason `progress_stall`, elapsed 1924 s (run 4145257 pass 1, 12:35) and 5832 s (run 3104859 pass 15, 05:09); **both with empty state** (no content beyond the header) |
| yield contracts | `WG/yield/phase3-attempt1-20261012-052705-3104859.json` (deadline 16200 s, resume_when file_exists chain2.done), `WG/yield/phase3-attempt1-20261013-120241-4145257.json` (final: adopt pid 3538140, resume_when pid, deadline 14400 s) | current yield valid + JSON; chain6-era rewrite history shows 4 rewrites same day (16200→14400→14400→18000→14400) — see anomaly H |
| yield-jobs | `WG/yield-jobs/phase3-attempt1-20261013-120241-4145257-yield1.{log,rc,pid,pid.launcher}` | chain3's yield job; rc=1; pids 436654/436653 both DEAD |
| failure-ledger | `WG/failure-ledger.jsonl` (2 failure signatures: `canary failed (CANARY-FAIL vrf-apply leaf01:` and `LAB-SICK … APPLY-STUCK`) | records only the two yield-job failures; **misses every other failure class in this dataset** (wedges differ receipts, false clean, poisoned records) — coverage gap |
| relaunch/launch logs | `MOL/relaunch-20261013.log`, `MOL/relaunch-20261012.log`, `MOL/milestones.log`, `MOL/milestones-archive-20261012-13.log`, `MOL/RELAUNCH-PROMPT-20261012.md` | 2026-10-13 sequence: supervise.py path bug → runtime.py `--mode auto` arg error (DIGEST exit 23) → DIGEST exit 22 (11:41:43 TERMINAL) → specstride start 11:40:54 run 3982362 → pass 1 → stop.flag halt exit 6 (11:55:19, `runs/20261013-114053-3982362/events.jsonl` event `run_stop reason=stop_flag`) → relaunch 12:02 run 4145257 (pid 4145257/4145722 visible in `ps`) |
| SIGINT incident record | `MOL/INCIDENT-20261012-launcher-sigint.md` + `MOL/.mixture-of-loops/runs/004-srv6-service-requests.stopped-exit130-20261012/` (state.json exit_reason "interrupted", harness-launch.log, launcher.log) | preserved run dir; incident report with corrected root cause (§8: dsh-web crash → systemd cgroup kill) |
| run records | `WG/runs/{20261011-214658-898303, 20261012-052705-3104859, 20261013-114053-3982362, 20261013-120241-4145257}/` (events.jsonl, run.log, verification plans, phase-2 attempt JSONs, accelerator before/after) | 4145257 events end 21:05:13 `yield_wait` (≤ snapshot cut 21:05:50) |
| launch contract | `MOL/launch-contract.json` (900 KB) + `WG/last-run.conf` | resolved flags of run 4145257 |
| proof slices (`p1-*.txt`, `p2-*.txt`, `p3-*.txt`) | `PROOF/*.txt` (53 files) | evidence slices citing the recorded proofs; `p3-proof-steering-*` slices describe the steering proofs as of Oct 12 18:12 — **stale vs the current steering garbage** (slice drift; refresh pending per yield on_resume) |
| GATE3 draft | `G3/evidence-final.md` (310 lines) | RECEIPT-* markers pending; verdict table already declares steering `proven` with an honest negative on the 5 s bound — **draft predates the current differ** (must be reconciled before publishing) |
| gate sweep logs | `G3/gate-*.log` (10 files: SID-list, H-Encaps-Red, End, End-DT46, Counters, Decapsulation, EVPN-Type3/5, evpn2, evpn2b, SRv6-Underlay) | all green (phase-3 qualify sweep evidence) |

## 4. Post-snapshot growth (noted, not analyzed)

Live marker check at writing time (read-only stats): `/tmp/g3/chain7.log` mtime 2026-10-13
21:02:16 = snapshot copy (no growth in chain7.log since the cut); `/tmp/g3/spike-rerun-evpn3.verdict`
20:57:22 = snapshot; `/tmp/g3/chain7.done` absent in both. chain7 (pid 3538140, elapsed 1:59:31)
and the keeper agent (pid 3195923, `claude --dangerously-skip-permissions`) were still alive.
R3-6 (the 6th evpn3 re-record) and the remaining R2/baseline phases were therefore still in
flight — this inventory is a point-in-time cut, exactly per ground rule 2.
