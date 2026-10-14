# Dataset inventory — feature 004 (SRv6 service requests), snapshot 2026-10-13 21:05:50 +04

All evidence read from the snapshot `evals/incidents/004-srv6-service-requests/raw/`
(`tmp-g3-20261013T210550/`, `wiggum-004-20261013T210550/`, `mol-004-20261013T210550/`).
Classification keys: `clean` | `differ` | `garbage` | `in-progress` | `missing-receipt` | `honest-negative`.

## 1. Proof groups under `wiggum-004-20261013T210550/gates/proofs/` (249 entries; `.cmd`/`.out` pairs verified complete — no orphan pair found)

| Group | Members | State @ snapshot | Evidence / failure marker |
| --- | --- | --- | --- |
| `p1-*` (phase 1) | p1-agents, p1-setup-unittest, p1-image-by-digest, p1-network-unaffected (4 proofs) | `clean` except `p1-image-by-digest` = `garbage` (stale RED record) | `p1-image-by-digest.out` ends `[exit code: 1]` — "pull access denied for local/sonic-vm" (2026-10-11 22:47); superseded by later phase-1 passing evidence (stale, deliberate red) |
| `p2-*` (phase 2) | p2-configmap-sonic-image, p2-pin-assert-live, p2-t005-guard (3 recorded proofs) | `clean` | `.out` files end `[exit code: 0]`; `p2-*` slices are `.txt` extracts |
| `q10-*` | q10-baseline, q10-srv6, q10-guard | `clean` | PROGRESS pass 15 "run-q10-* rc=0" (`PROGRESS.md` ~line 901); `.out` files `[exit code: 0]` |
| `q14-*` | q14-probe, q14-gate-vm, q14-report-vm | `clean` | `.cmd`/`.out` pairs present, `[exit code: 0]` |
| `clab-digest-proof` | directory only (`clab.yml`) | `missing-receipt` (not a replay group; no `.cmd`/`.out`) | `gates/proofs/clab-digest-proof/clab.yml` |
| `selftest` | selftest | `clean` | `selftest.out` `[exit code: 0]` (2026-10-13 04:39) |
| `spike-factory-*` | 4 proofs (one per node) | `clean` | recorded 2026-10-12, `[exit code: 0]` |
| `spike-identity-*` | 4 proofs | `clean` | idem |
| `spike-underlay-*`, `spike-kernel-*`, `spike-locator-*`, `spike-portmap-*`, `spike-counters`, `spike-persistence`, `spike-sid-write`, `spike-vrf-apply-leaf01` | ~24 proofs | `clean` | all `[exit code: 0]`; pass 15 integrity sweep: "all 70 recorded spike proofs end [exit code: 0]" (`PROGRESS.md` pass 15) |
| `spike-baseline` (4) | spike-baseline-{spine01,spine02,leaf01,leaf02} | `differ` — receipt STALE relative to members | `spike-rerun-baseline.out` (11:32): "differ: spike-baseline-spine02 … 1 of 4 proof(s) differ `[exit code: 1]`"; members re-recorded 15:24 (chain6 phase A) AFTER the receipt → receipt cannot cover current records |
| `spike-vpn` (8) | spike-vpn-{state-leaf01,state-leaf02,ping,capture,readback-leaf01,readback-leaf02,clients,rollback} | `clean` | `spike-rerun-vpn.out` (19:37): "8 proof(s) checked, no difference `[exit code: 0]`" — first clean vpn receipt, after keeper heal + vrf-apply wedge cure (`chain7.log` lines 8–10) |
| `spike-steering` (5) | spike-steering-path, spike-steering-failover-{launcher,guest-if,bgp}, spike-steering-return | `garbage` ×2 + `differ` receipt | `spike-steering-path.out` and `spike-steering-failover-launcher.out` = `PREFLIGHT-FAILED … [exit code: 1]` (recorded 19:59 / 20:25 during wedge #6); `spike-rerun-steering.out` (20:44): "2 of 5 proof(s) differ `[exit code: 1]`" — an HONEST differ this time (it correctly flags the two garbage members); D-3/D-4/D-5 re-recorded green 20:38–20:40 |
| `spike-evpn3` (6) | spike-evpn3-{ping,capture,kl006,rollback,state-leaf01,state-leaf02} | `in-progress` re-record (R3-1..R3-6) + stale `differ` receipt | `spike-rerun-evpn3.out` (20:57): "3 of 6 differ `[exit code: 1]`"; members then re-recorded green 20:58–21:02+ (`chain7.log` R3-1..R3-6) — snapshot cut mid-re-record, receipt now temporally invalid. Group verdict is `honest-negative` (routed EVPN over SRv6 not achievable on this image, `PROGRESS.md` pass 8) |
| `spike-evpn2` (5) | spike-evpn2-{state-leaf01,state-leaf02,ping,capture,rollback} | `differ` (receipt 10:40 live vs stored members of 2026-10-12) | `spike-rerun-evpn2.out`: "2 of 5 proof(s) differ" (ping, rollback) `[exit code: 1]`; honest-negative group (bridged EVPN/L2VNI: signalling works, service not deliverable, `PROGRESS.md` pass 8b) — replay never re-run after keeper heal at snapshot time |

## 2. Chain log series (`tmp-g3-20261013T210550/`)

| Dataset | State | Evidence |
| --- | --- | --- |
| `chain2.log/.summary/.done/.pid/.sh` | COMPLETE, poisoned outputs | summary: `spike-rerun-steering=clean` (FALSE clean 08:39), vpn/evpn3/evpn2/baseline `differ`; D-1..D-5 all rc=1 07:12–07:50 (`chain2.log` ##### lines) |
| `chain3.log/.summary/.done/.sh` | aborted LAB-SICK (false negative) | summary `FINAL: LAB-SICK … CANN=1` 13:52:42; zero recordings |
| `chain4.log/.pid/.sh` | killed 14:12, phase A poisoned | `PROGRESS.md` pass 23: baselines ×4 re-recorded 14:08 on half-removed lab |
| `chain5.log/.summary/.done/.sh` | aborted in H, real wedge #4 | summary: all five verdicts `missing`, `FINAL: LAB-SICK … APPLY-STUCK` 14:30:42 |
| `chain6.log/.summary/.done/.pid/.sh` | keeper-aborted 19:17 | summary: vpn receipt differ 7/8 APPLY-STUCK (17:59); steering garbage 18:08–19:09; E/F/G never ran |
| `chain7.log/.sh` | LIVE at snapshot (R3-6 in flight) | `chain7.log` line 56: R3-6 started 21:02:16, no RC yet at 21:05:50; no `.summary`/`.done` yet |
| `spike-rerun-{vpn,steering,evpn3}.verdict` | present (`clean`/`differ`/`differ`) | `tmp-g3-*/spike-rerun-*.verdict`; evpn2/baseline verdict files absent at snapshot |

## 3. Run-level datasets

| Dataset | State | Evidence |
| --- | --- | --- |
| `PROGRESS.md` (~1323 lines, passes 1–25) | clean journal | `wiggum-004-*/PROGRESS.md` |
| `pass-checkpoints/*.md` (13 files) | 9 watchdog kills recorded | e.g. `…4145257-phase3-attempt1-pass1-20261013-123553.md`: `reason: progress_stall, elapsed: 1924s` |
| `yield/*.json` (2) | valid; final deadline 14400 s for chain7 | `yield/phase3-attempt1-20261013-120241-4145257.json` |
| `failure-ledger.jsonl` | 2 failure signatures (yield1 canary, yield2 chain5 LAB-SICK) | file content |
| `verdicts/`, `attempts/`, `runs/`, `gates/` | phase 1–2 critic verdicts present | dir listing |
| `mol-004-*/relaunch-20261013.log` | records 11:40 start, stop.flag exit 6, `runtime.py: error: unrecognized arguments: --mode auto` → `state=failed exit=23` | log lines 5–35 |
| `mol-004-*/INCIDENT-20261012-launcher-sigint.md` | SIGINT exit 130 post-mortem | file |
| `mol-004-*/milestones*.log`, `watcher.log`, `launch-contract.json` | `[MOL-GATE]` / milestone records | dir listing |
| `evidence-final.md` (GATE3 draft) | RECEIPT-* markers pending at snapshot | `tmp-g3-*/evidence-final.md` (per `PROGRESS.md` pass 19/25) |

## 4. Garbage/differ root causes (summary)

- `spike-steering-path.out` + `spike-steering-failover-launcher.out`: marker `PREFLIGHT-FAILED: client01 -> client02 does not pass … refused` + `[exit code: 1]` — recorded 19:59/20:25 while wedge #6 had the dataplane dead (`chain7.log` D-1-r2/D-2-r2 rc=1).
- `spike-rerun-*.out` receipts: differ exits caused by (a) orchagent wedge during replay (chain6 vpn 7/8 APPLY-STUCK), (b) replay of self-identical garbage (chain2 steering "clean" 08:39 = false clean), (c) volatile-byte/jitter differs on drifted labs (chain2 baseline spine02, evpn3/evpn2).
