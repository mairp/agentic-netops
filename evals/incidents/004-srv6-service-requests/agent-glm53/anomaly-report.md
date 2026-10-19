# Anomaly report — checks A–J (Worker B: agent-glm53)

Deterministic checks over the snapshot `evals/incidents/004-srv6-service-requests/raw/`
(shorthands: `G3` = `raw/tmp-g3-20261013T210550`, `WG` = `raw/wiggum-004-20261013T210550`,
`PROOF` = `WG/gates/proofs`, `MOL` = `raw/mol-004-20261013T210550`). Snapshot cut
2026-10-13 21:05:50 +04. All commands were re-run against the snapshot at curation time;
every number below is measured, not copied.

## Summary table

| Check | Finding | Severity | Verdict (one line) |
| --- | --- | --- | --- |
| A false-clean | no live hit; 1 historical hit (INC-004-022) | critical (historical) | The 08:39 clean was garbage-over-garbage; at snapshot all clean receipts sit on green members, so check A alone would have caught it only on Oct-12-era state — needs member-failure scan at receipt time. |
| B recorded-failure inventory | 3 non-zero member `.out` + 1 footer anomaly | major | 2 live garbage (steering path/launcher), 1 honest-negative (`p1-image-by-digest`), 1 format anomaly (`p1-network-unaffected` missing footer). |
| C rc/verdict mismatch | 21 non-zero `.rc` files; 2 unverifiable verdict claims | major | Most are superseded; live: 4 receipt `.rc=1` + `D-*` garbage; `chain5.done` mislabeled `CHAIN4-DONE(lab-sick)`; chain5 wrote no verdicts at all. |
| D temporal invalidation | 2 invalid receipts | major | `spike-rerun-evpn3` (20:57:22) has 5/6 members recorded AFTER it (20:58:59–21:02:16); `spike-rerun-baseline` (11:32:02) has 4/4 members re-recorded at 15:24 after it. |
| E missing pair / phantom | 87/87 pairs balanced; 1 phantom order entry | minor | `restore-check` in `.record-order` (88 entries) with no `.cmd`/`.out`. |
| F stale pid | 4 dead pid files + 1 missing pid file + wrapper confusion | minor | chain2/chain4/chain6 + yield1 pids DEAD; `chain7.pid` absent (pid 3538140 lives only in the yield JSON, verified ALIVE); chain4 pid is the wrapper (kill used 935363). |
| G provenance gap | `scripts/spike/` untracked | major | Entire proof-body library outside version control; `git check-ignore` has no rule. |
| H yield-budget mismatch | 1 hit (chain6 era) | major | 18000 s armed vs ~24600 s of work implied by actual cadence (16500 s spent + ~8100 s remaining at abort); chain7's 14400 s fits its remaining plan. |
| I garbage loop | 2 true hits (+ benign duplicates distinguished) | major | `D-1.log` ≡ `D-1-r2.log` (3520ea1e…) and `D-2.log` ≡ `D-2-r2.log` (85e56758…) — identical failures re-recorded; 12 converge logs share md5 c1e0e2e8… (benign: deterministic probe); zero duplicate `.out` bytes. |
| J control (future mtimes) | clean | control | Max snapshot mtime 21:05:13 (`runs/20261013-120241-4145257/events.jsonl`) < cut 21:05:50; zero future-dated files. |

## Check A — false-clean receipts

Method: for each `spike-rerun-*.out` receipt, require NOT(clean + any member `.out`
matching `PREFLIGHT-FAILED|APPLY-STUCK|VPN-SETUP-STUCK|LAB-SICK|[exit code: [1-9]`).

- `spike-rerun-vpn.out` (19:37:15) — clean 8/8, `[exit code: 0]`; all 8 member `.out` green
  (16:57–17:06 chain6 records) → **no hit**.
- `spike-rerun-steering.out` (20:44:38) — `differ: spike-steering-path`,
  `differ: spike-steering-failover-launcher`, `[exit code: 1]` → receipt itself reports
  differ → **no live hit** (and the two differ members ARE the failure-marker files, so the
  receipt and the inventory agree).
- `spike-rerun-baseline.out` (11:32:02), `spike-rerun-evpn2.out` (10:40:05),
  `spike-rerun-evpn3.out` (20:57:22) — all `differ` → no false clean (validity handled in D).
- **Historical hit (proven, not present at snapshot):** chain2.log records
  `spike-rerun-steering verdict=clean` at 08:39 after the 07:12–07:50 D-phase had
  overwritten all five steering `.out` with PREFLIGHT-FAILED garbage — garbage-over-garbage
  clean (INC-004-022). Evidence: `G3/chain2.log` (07:12–08:39 lines), PROGRESS.md:1165-1168
  (audit), `MOL/relaunch-20261013.log` ("1 false clean").
- Note: `PROOF/.tmp.cap.*` shows the capture preflight temp pattern; the preflight that
  refuses bad captures (steering-path.sh line 18) was added AFTER the dead-dataplane
  0/0-SRH-capture exit-0 incident of 2026-10-13 (script comment) — the historical guard gap.

## Check B — recorded-failure inventory (non-zero member `.out`)

Full scan of 82 member `.out` (87 minus 5 receipts), last-line footer parse + marker grep:

| Member `.out` | Last line | Failure marker | Classification |
| --- | --- | --- | --- |
| `PROOF/spike-steering-path.out` | `[exit code: 1]` | `PREFLIGHT-FAILED: client01 -> client02 does not pass; steering capture refused` | **live garbage** (recorded 19:59:11 during the 6th-wedge window) |
| `PROOF/spike-steering-failover-launcher.out` | `[exit code: 1]` | `PREFLIGHT-FAILED` (launcher variant) | **live garbage** (recorded 20:25:02, same window) |
| `PROOF/p1-image-by-digest.out` | `[exit code: 1]` | none | **honest-negative** — deliberate negative probe proving the pin assertion fires (correct result, not a failure) |
| `PROOF/p1-network-unaffected.out` | last line = kubectl event `Warning ApplyFailed network/migr-…` | exit-0 records but **missing the trailing `[exit code: N]` footer** (67 lines; body contains 10 exit-code strings from redis-cli exit-127 kubectl events) | **format anomaly** — the proof.sh footer invariant is violated; a parser keying on the footer mis-reads this file (fixture value) |

Everything else: 78 member `.out` end `[exit code: 0]` → clean records at snapshot.

## Check C — rc/verdict mismatch

21 non-zero `.rc` files in `G3/`: `CANN=1, converge5=1, D-1=1, D-1-r2=1, D-2=1, D-2-r2=1,
D-3=1, D-4-r2=1, FG-spike-vpn-canary=1, G-seed=1, H-canary=1, P-provision=1, PROV=1,
Q1-canary=1, Q1-recover=1, receipts3=3, R-receipt=1, spike-rerun-baseline=1,
spike-rerun-evpn2=1, spike-rerun-evpn3=1, spike-rerun-steering=1`.

- **Superseded (stale):** `P-provision=1` (chain2 tolerated it; later provisions green),
  `Q1-canary/Q1-recover/CANN=1` (chain3's false-negative canary, INC-004-019), `G-seed=1`
  (10:42; superseded by `A-seed` green 15:24 — and `A-seed.log` ≡ `R-seed.log` md5 4f9e5354…),
  `H-canary=1` + `FG-spike-vpn-canary=1` (chain5/chain6 canary fails superseded by chain7
  `H2-canary` green), `converge5=1`/`PROV=1` (chain5-era, superseded), `receipts3.rc=3`
  (pass-16 receipt-abort loop; the rc=127 poison was separately noted/deleted per
  PROGRESS.md:1277-1279).
- **Live:** `D-1/D-1-r2/D-2/D-2-r2/D-3/D-4-r2=1` (steering garbage, INC-004-024 — note
  `D-3=1` is the first attempt while `D-3-r2` succeeded rc=0), and the four receipt
  `.rc=1` (`spike-rerun-{baseline,evpn2,evpn3,steering}`) which are the honest differ state.
- **Verdict claims without evidence:** `G3/chain5.done` says `CHAIN4-DONE(lab-sick)` — the
  chain5 marker is labeled chain4 (INC-004-024 family: provenance slop), and chain5 wrote
  **no** `.verdict` files at all despite declaring LAB-SICK; `G3/spike-rerun-*.verdict`
  exists only for vpn=clean / steering=differ / evpn3=differ — `evpn2`/`baseline` verdicts
  exist only inside their `.out` files.

## Check D — temporal invalidation (member mtime > receipt mtime)

| Receipt | Receipt mtime | Members recorded after it | Verdict |
| --- | --- | --- | --- |
| `spike-rerun-vpn.out` | 19:37:15 | none (members 16:57–17:06) | valid |
| `spike-rerun-steering.out` | 20:44:38 | none (members 19:59–20:40) | valid as a differ statement |
| `spike-rerun-evpn3.out` | 20:57:22 | **5 of 6**: ping 20:58:59, capture 21:00:12, kl006 21:00:52, rollback 21:01:41, state-leaf01 21:02:16 (state-leaf02 17:05 predates) | **INVALID** — the differ (ping, rollback, state-leaf01) refers to pre-fallback records; R3 fallback was overwriting them at snapshot; `G3/R3-6.log` exists but is EMPTY (0 B, md5 d41d8cd9…) = sixth re-record in flight at cut |
| `spike-rerun-evpn2.out` | 10:40:05 | none (members 2026-10-12) | valid statement about old records; group awaiting its R2 fallback |
| `spike-rerun-baseline.out` | 11:32:02 | **4 of 4** (spine01/leaf01/leaf02/spine02 15:24:43–15:24:56) | **INVALID** — its `differ: spike-baseline-spine02` judged records replaced 4 h later |

## Check E — missing pairs / phantom order entries

- 87 `.cmd` / 87 `.out` — pair sets identical (no orphans in either direction).
- `.record-order` = 88 entries; exactly one phantom: **`restore-check`** (no pair anywhere
  in `PROOF/`) → the canonical order counts a proof that cannot be replayed (INC-004-031).

## Check F — stale pid files

| Pid file | Value | State at curation |
| --- | --- | --- |
| `G3/chain2.pid` | 1024502 | DEAD (outlived by 10+ h) |
| `G3/chain4.pid` | 935362 | DEAD — and it is the **wrapper**; PROGRESS.md:1227-1234 records the kill of 935363 |
| `G3/chain6.pid` | 1226866 | DEAD (keeper kill 19:17; summary written) |
| `WG/yield-jobs/…yield1.pid` / `.pid.launcher` | 436654 / 436653 | both DEAD |
| `G3/chain7.pid` | — | **ABSENT**; the live pid 3538140 exists only inside the yield JSON (`WG/yield/phase3-attempt1-20261013-120241-4145257.json`) and was verified ALIVE at curation (chain7 elapsed 1:59:31) |

## Check G — provenance gap

- `git status --porcelain scripts/spike/` → `?? scripts/spike/` (untracked, not staged).
- `git check-ignore -v scripts/spike/` → rc=1 (no ignore rule — it is plain untracked).
- Last commit at snapshot: `e56e0b40` 2026-10-12 06:15 "specstride: phase 2 approved" — the
  whole phase-3 proof library postdates it and was never committed (INC-004-028).

## Check H — yield-budget mismatch

- `WG/yield/phase3-attempt1-20261013-120241-4145257.json` (final): adopt pid 3538140,
  `deadline_sec: 14400`. History of the same file: 4 rewrites on 2026-10-13
  (16200 → 14400 → 14400 → 18000 → 14400). The chain6-era 18000 s arm was infeasible at
  arm time: chain6 actually consumed 16500 s (14:42→19:17) and still needed ~8100 s of
  fallback work (keeper's own estimate at abort) ⇒ ~24600 s needed vs 18000 s armed
  (`inferred:` the 8100 s figure is the keeper's journal estimate, not a measured queue).
- chain7's 14400 s (expires 23:33) vs remaining plan at snapshot (finish R3-6, evpn3
  receipt, R2 evpn2 fallback + receipt, baseline receipt; observed cadence ~1–2 min per
  re-record, receipts 2–10 min) ⇒ plausible fit — no hit.

## Check I — garbage loop (byte-identical failure re-records)

True hits (identical FAILURE, no remediation between):
- `G3/D-1.log` ≡ `G3/D-1-r2.log` — md5 `3520ea1e962bb5553e798b6bfc5cfe44`.
- `G3/D-2.log` ≡ `G3/D-2-r2.log` — md5 `85e567585dd0e5cd8d4a0b7f07ea2eb5`.

Benign duplicates (deterministic success output — listed to keep the check honest):
`C-x.log` ≡ `RV-x.log` for x=1..8 (chain6 re-record reproduced byte-identical success),
`canary|hc|pre|smoke-{l1,l2,vpnsetup}.log` quadruples (silent-on-success scripts),
12 converge logs sharing md5 `c1e0e2e870db3bc33aecc30329683737`, `A-b-*.log` ≡ `R-b-*.log`,
`A-dry.log` ≡ `R-dry.log`, `R-receipt.log` ≡ `spike-rerun-baseline.log`,
`FG-spike-evpn3-canary.log` ≡ `H2-canary.log` ≡ `R-canary.log`. Zero duplicate bytes among
the 87 `.out` files (the steering garbage differs by node/mode suffix text).

## Check J — control: future mtimes

`find <snapshot> -newermt '2026-10-13 21:05:50'` → **0 files**. Newest snapshot file:
`WG/runs/20261013-120241-4145257/events.jsonl` at 21:05:13 (37 s before the cut) —
the snapshot is internally consistent as a point-in-time cut.

### Additional finding (out-of-band, format hygiene)

`PROOF/.tmp.cap.{2AEoAl,c2dE2h,Ds7Tdl,MmKK3A,wAsUBY}` — **five** leaked temp files
(Oct 12 20:32, Oct 12 22:40 with 62 B content, Oct 13 05:16, 19:09, 21:02:16; four empty).
vpn-capture.sh's preflight/capture temp files are not cleaned on failure paths; the last
one (21:02:16) was being written exactly when R3-6's capture stage was in flight.

## Checks the harness lacks (→ harness-regression evals)

None of A–J is currently automated by specstride/.mixture-of-loops machinery — the pass
journal shows every one of these was found by human/agent reading. Highest-value gaps:

1. **A (false-clean gate)** — refuse `clean` when any member `.out` has a failure marker or
   non-zero footer (would have caught 08:39).
2. **D (receipt staleness)** — receipts must embed member hashes/mtimes; consumers reject
   receipts with any member newer than the receipt (would have flagged baseline + evpn3).
3. **B (recorded-failure inventory + footer invariant)** — scan stored `.out` for failure
   markers/non-zero footers and enforce the trailing `[exit code: N]` footer (catches live
   garbage + the p1-network-unaffected format hole).
4. **E (record-order integrity)** — order entries must have persisted pairs (catches the
   restore-check phantom).
5. **F (pid hygiene)** — validate pid files (alive, correct process) before supervision
   actions; remove on exit; record group leader not wrapper.
6. **H (yield feasibility at arm)** — compare `deadline_sec` against cadence-derived
   remaining work at arm time (would have caught chain6's 18000 s).
7. **I (garbage-loop tripwire)** — refuse to store a failure output byte-identical to the
   previous attempt's (would have stopped the D-phase loop at attempt 2).
