# Curation report — feature 004 (SRv6 service requests), Worker A (agent-qwen38)

Snapshot analyzed: `evals/incidents/004-srv6-service-requests/raw/` (2026-10-13 21:05:50 +04).
Run state at snapshot: LIVE — chain7 executing (R3-6 evpn3 re-record in flight at cut time);
keeper active. No writes outside this worker directory were performed.

## Deliverables (all in `evals/incidents/004-srv6-service-requests/agent-qwen38/`)

| File | Content |
| --- | --- |
| `dataset-inventory.md` | Every proof group under `gates/proofs/` + chain-log series + run-level datasets, classified |
| `incidents.md` | Chronological narrative, 29 incidents, artifact citations |
| `incidents.jsonl` | 29 structured records — VALIDATED line-by-line |
| `anomaly-report.md` | Checks A–J all run, with a "checks the harness lacks" section |
| `cases.jsonl` | 19 eval cases — VALIDATED line-by-line |
| `EVAL-004-001..019.md` | One file per case (fixtures inline, self-contained) |
| `report.md` | This file |

## Counts

**Incidents: 29**, by class — script-bug 8, orchagent-wedge 4, run-incident 4,
poisoned-record 3, keeper-intervention 2, design-gap 2, other 2, false-clean-receipt 1,
yield-incident 1, provenance-gap 1, honest-negative 1. Every incident cites ≥1 artifact;
JSONL re-validated after final write; every incident class has ≥1 derived eval.

**Evals: 19** — 10 agent-behavior (checklist), 9 harness-regression (deterministic).
All 11 incident classes covered (verified programmatically: uncovered set is empty).

**Anomalies found (A–J):** A: 1 historical false-clean confirmed + current receipts clean;
B: 1 stale red record, 2 live garbage member records; C: 3 hits (uncovered rc≠0, missing
verdicts, verdict/receipt gaps); D: 2 temporally invalid receipts (baseline, evpn3); E: 1 hit
(`restore-check` in `.record-order` with no record); F: confirmed (wrapper-race pid + missing
chain7.pid); G: confirmed (`?? scripts/spike/`); H: confirmed (chain6 18000 s infeasible);
I: marker-level loops confirmed, zero byte-identical pairs; J: clean (no future mtimes).

## Top-5 anomalies

1. **False-clean steering receipt, 08:39 (INC-009)** — chain2 replayed five PREFLIGHT-FAILED
   garbage records over themselves and returned verdict `clean` + exit 0
   (`tmp-g3-*/chain2.log` lines 45–57). The receipt mechanism has no member-health notion.
2. **Six orchagent wedges (INC-001/005/011/018/019/023)** — recurring CONFIG_DB→APPL_DB
   consumer stall that poisons records AND replays; remedies measured (in-guest cure ~3 min
   vs provision ~25 min; `docker restart swss` harmful), cure now scripted in
   `scripts/spike/vrf-apply.sh`.
3. **Poisoned re-records destroyed good evidence twice (INC-008, INC-017)** — steering
   proofs overwritten with garbage 07:12–07:50; baselines recorded on a half-removed lab
   14:08 — in both cases the chain kept recording after a failed precondition.
4. **Seed-restore silent no-ops + leafref ordering (INC-004/011/017)** — three silenced
   mechanism bugs (`config gcu`, launcher-fs `docker cp`, wrong script name) plus a
   /VRF-before-/INTERFACE removal order violating sonic_yang leafrefs; all hidden by `|| true`.
5. **Stale receipts + missing freshness binding (INC-026, anomaly D)** —
   `spike-rerun-baseline.out` (11:32) predates its 15:24 members; `spike-rerun-evpn3.out`
   (20:57) predates its 20:58–21:02 re-records. Nothing voids a receipt whose group changed.

## Top-5 evals

1. **EVAL-004-001** wedge triage before a queued replay (the highest-stakes recurring decision).
2. **EVAL-004-002** refuse a false-clean receipt (garbage-over-garbage detection).
3. **EVAL-004-011** harness check A: receipt gate must refuse clean when members carry
   failure markers.
4. **EVAL-004-012** harness check D: receipt freshness binding (temporal invalidation).
5. **EVAL-004-018** harness check H: yield-budget feasibility must be flagged at arm time.

## Post-snapshot growth

The live run was still recording at snapshot time: chain7's R3-6 (`chain7.log` 21:02:16)
had no RC at 21:05:50, so the evpn3 group's re-record and its eventual receipt are beyond
this analysis. Not deep-analyzed per ground rules.

## UNVERIFIED

- **INC-012 root cause** (dsh-web.service crash → systemd cgroup kill): taken from the
  incident file's own §8 claim (`mol-004-*/INCIDENT-20261012-launcher-sigint.md`); the host
  journal itself is outside the snapshot — UNVERIFIED from snapshot evidence alone.
- **`/root/specstride/proposer.sh` exit-6/exit-9 semantics** (INC-014/021): live reference
  file, not part of the snapshot; cited per the task's evidence map, not independently read
  line-by-line here beyond the relaunch log's own "exit 6" text — partially UNVERIFIED.
- **chain2-era verdict "clean" byte content**: the 08:39 false-clean receipt text itself was
  overwritten by the 20:44 re-run in the stored `.out`; confirmed via `chain2.log`/
  `chain2.summary`/PROGRESS pass 20 instead — the original bytes are UNVERIFIABLE from the
  snapshot.
- **`restore-check`** (anomaly E): appears in `.record-order` with no stored pair; whether it
  was later renamed or its records deliberately deleted is UNVERIFIED.
- **Wedge occurrence count "6"**: 6 occurrences reconstructed from PROGRESS.md passes
  15/18/20 + chain5/6/7 summaries; the first (pass 15, 2026-10-12 ~21:26) predates detailed
  swss.rec capture, so its classification as the same signature is inferred from the pass-24
  retrospective.

## Open questions

1. Should `spike-steering-path.out` / `spike-steering-failover-launcher.out` (live garbage)
   be re-recorded by chain7's successor, or preserved as wedge evidence? (Recommend:
   preserve a copy as incident evidence, then re-record.)
2. evpn2's differ receipt (10:40) has never been re-run on a healed lab — the honest-negative
   verdict makes re-record optional, but the current differ mixes verdict text with
   drift-jitter; a normalizer audit is needed before the GATE3 receipt sweep.
3. `.record-order` completeness (`restore-check`) needs a canonical decision: backfill the
   record or remove the order entry.
