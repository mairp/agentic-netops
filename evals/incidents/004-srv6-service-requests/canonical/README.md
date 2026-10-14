# Canonical dataset — 004-srv6-service-requests

Reconciled union of the two independent curation passes:

| Source | Model | Dir | Incidents | Cases |
| --- | --- | --- | --- | --- |
| A | qwen3.8-27b (subagent) | `../agent-qwen38/` | 29 | 19 |
| B | glm-5.3-flash (dsh headless) | `../agent-glm53/` | 33 | 17 |
| **canonical** | supervising agent | `./` | **44** | **23** |

## Files

- `incidents.jsonl` — 44 records. Every record keeps its originating worker's
  full fields plus:
  - `source`: `["A","B"]` (24 records — both curators independently reported the
    same event: the highest-confidence class), `["A"]` (5), `["B"]` (15).
  - `cross_ref_b` — on A-origin records: the B-side id of the same event, into
    `../agent-glm53/incidents.jsonl` (null when A-only).
  - `orig_id` — on B-origin records: the id under which it appears in
    `../agent-glm53/incidents.jsonl`.
  - `merge_note` — where the match is "same family, different emphasis" or one
    worker consolidated what the other decomposed.
- `cases.jsonl` — 23 records, same provenance fields; `derived_from` references
  canonical incident ids (B-side references were remapped).
- `merge-map.py` — the supervised merge (hand-verified duplicate table;
  deterministic; re-runnable after a re-intake).
- `disagreement.md` — output of the earlier coarse auto-merge, kept for audit.

## ID scheme

- Incidents `INC-004-001..029` = Worker A's numbering (kept verbatim);
  `INC-004-030..044` = B-only incidents, renumbered (original id in `orig_id`).
  **Never assume a number: two different workers used the same numbers for
  different incidents** (e.g. B's `INC-004-005` = OTLP race ≠ A's `INC-004-005`
  = wedge #3 sick-lab re-record).
- Cases `EVAL-004-001..019` = Worker A's numbering; `EVAL-004-020..023` = B-only.
  Human-readable fixtures (scenario + expected checklist) live in each worker
  dir as `EVAL-004-NNN.md`, keyed by the *worker-local* id (see `orig_id` /
  `cross_ref` for the translation).

## Reading the provenance

- **24 double-verified incidents** are the core regression set: two independent
  models, no shared context, both found them. They include the false-clean
  receipt, all six wedge occurrences (A decomposes, B consolidates — see
  `merge_note` on INC-004-001/011/018/019/023 → B's INC-004-020), the seed-restore
  no-ops, chain3 canary false-negative, chain4 leafref poisoning, the stop.flag /
  SIGINT / watchdog run incidents, yield-budget infeasibility, the provenance gap,
  and the stale-receipt design gap.
- **15 B-only incidents** are B's genuine additions (mostly phase 1–2 era:
  GATE2 script-file mistake, OTLP replay race, T024 drift, T104 qualify gate,
  DEVICE_METADATA factory fields, bgpcfgd restart race, export-knob leak,
  evpn3-setup RR builder bug, vpn-rollback SyntaxError, docker-restart-swss
  lesson, restore-check phantom, baseline whitespace churn,
  CONTEXT_WINDOW_EXCEEDED). They passed B's own citation spot-checks; treat as
  single-sourced until a third pass or a re-intake confirms them.
- **5 A-only** (pass-17 keeper kill, MAC/EUI-64 normalization, chain2
  WARN-continue, receipts.sh mode-600, honest-negative classification) — same
  status.
- **Disagreement is signal.** Where the sets differ in *structure* (A splits the
  wedge timeline into 6 incidents, B consolidates into 1 + a remedy lesson), the
  `merge_note` records both views. Where one side is silent on an event the other
  reports, that is an unverified single-sourced incident — flag it in the next
  curation pass.

## Status

Reconciled 2026-10-13 ~22:00 +04 from snapshot `raw/*-20261013T210550/`.
The live run (chain7) was still executing at snapshot time; post-snapshot
growth (R3-6 evpn3-state leaf02, remaining receipts) is NOT in this dataset —
re-intake per `../PROVENANCE.md` when the run settles.
