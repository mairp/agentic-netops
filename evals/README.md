# evals/ — failure datasets → incidents → anomalies → evals

Reusable regression knowledge distilled from the failure history of autonomous
specstride runs. Started with **feature 004 (SRv6 service requests)**, whose
phase-3 feasibility gate spent ~2 days in an orchagent-wedge loop (6 recorded
wedges, one false-clean receipt, two poisoned re-record episodes, one keeper
intervention) before converging.

## Layout

```
evals/
├── README.md                     ← you are here
├── anomaly-scan.py               ← deterministic anomaly inspector (checks A–J),
│                                   reference implementation for harness-regression evals
├── reconcile.py                  ← coarse auto-merge of two worker dirs (first pass;
│                                   the supervised merge is canonical/merge-map.py)
├── prompts/
│   └── curate-failures-to-evals.md   ← the grounded curation prompt (the deliverable
│                                       that drives a research agent through the
│                                       whole identify→record→curate→inspect→evals pipeline)
└── incidents/
    └── 004-srv6-service-requests/
        ├── PROVENANCE.md         ← snapshot manifest, live context, re-intake recipe
        ├── raw/                  ← point-in-time evidence snapshots (the only durable
        │   ├── tmp-g3-<ts>/          copy of /tmp/g3: chain scripts/logs/summaries,
        │   ├── wiggum-004-<ts>/      per-step .log/.rc, verdicts, GATE3 draft
        │   └── mol-004-<ts>/         PROGRESS.md, gates/proofs, checkpoints, yields
        ├── anomalies/            ← scanner outputs (report + json per scan)
        ├── agent-qwen38/         ← Worker A outputs (incidents, anomalies, evals)
        ├── agent-glm53/          ← Worker B outputs (same contract)
        └── canonical/            ← RECONCILED dataset (44 incidents, 23 eval cases):
                                    incidents.jsonl, cases.jsonl, provenance fields,
                                    merge-map.py (the supervised merge), README.md
```

## The pipeline (what the prompt does)

1. **Identify the datasets the agents failed on** — every proof group under
   `gates/proofs/` (`<name>.cmd` + `<name>.out`, replay receipts
   `spike-rerun-*.out`), chain log series, run-level artifacts — classified
   `clean | differ | garbage | in-progress | missing-receipt | honest-negative`.
2. **Record** — volatile evidence (`/tmp/g3`) snapshotted into `raw/` with a
   provenance manifest before anything else.
3. **Curate** — structured `incidents.jsonl` (schema in the prompt): class,
   severity, root cause, responsibility (environment/agent/script/design),
   actual vs expected-correct behavior, detection signal, affected datasets.
4. **Inspect anomalies** — deterministic checks A–J (false-clean receipts,
   recorded failures, rc/verdict mismatches, temporal invalidation of receipts,
   missing pairs, stale pids, provenance gaps, yield-budget infeasibility,
   garbage loops, future mtimes) — run by `anomaly-scan.py` and by the workers.
5. **Create evals** — per incident class: agent-behavior evals (scenario +
   fixture + expected checklist, gradable with any dsh model) and
   harness-regression evals (deterministic properties the specstride machinery
   should enforce — e.g. "a receipt with failure-marked members must not be
   clean", "a yield whose deadline can't cover remaining work must be flagged
   at arm time").

## Operating notes

- **The source run is LIVE.** Everything under `raw/` is read-only evidence;
  analysis reads come from snapshots, never from the live tree. Re-intake
  (new snapshot + delta) per `PROVENANCE.md` whenever a new failure episode
  lands — then re-run the prompt (or just the anomaly scan):
  `python3 evals/anomaly-scan.py evals/incidents/004-srv6-service-requests/raw \
     --repo /root/agentic-netops --report <new>.md --json <new>.json`
  (exit 1 = anomalies found — that is the intended regression-test semantics).
- **Two-worker protocol.** Two independent agents run the same prompt into
  `agent-<model>/` dirs; the supervising agent reconciles into canonical files.
  Disagreement between the two incident sets is treated as an anomaly signal in
  its own right.
- **Honest negatives are not incidents.** evpn variants proved
  `not-achievable` on the pinned image — that is correct evidence, classified
  `honest-negative`, and is used for evals about *not* misreporting.

## Status (2026-10-13 22:00 +04)

- Snapshot #1 taken (21:05:50), provenance written.
- `anomaly-scan.py` v1 running: 22 findings on snapshot #1 (incl. confirmed
  provenance gap: 44 spike scripts untracked in git; 2 temporally-invalid
  receipts; chain2 yield overage).
- Worker A (qwen3.8): **done** — 29 incidents, 19 evals, all checks A–J,
  honest UNVERIFIED list.
- Worker B (glm-5.3-flash via dsh headless): **done** — 33 incidents, 17 evals,
  all checks A–J, citation spot-checks, honest UNVERIFIED list.
- **Canonical reconciliation: done** — `canonical/` holds 44 incidents
  (24 double-verified by both independent curators) and 23 eval cases
  (13 double-verified), with per-record provenance + cross-refs.
- Next: re-intake a snapshot #2 once chain7 settles (post-snapshot growth is
  not yet in the dataset); optionally a third curation pass to confirm the
  20 single-sourced incidents.
