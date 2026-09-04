# Intent Tier Acceptance Report

This report aggregates simulation outcomes for Phase 11.

## Acceptance scenario results

| Scenario | Result |
|---|---|
| Tier bring-up success (from clean) | See docs/INTENT_TIER_OPS_READINESS.md (cold-read timing) |
| First-pass interpretation accuracy | 100.00% |
| Unsupported-refusal rate | 0.00% |
| Direct-action refusal rate | 0.00% |
| Idempotence (unchanged intent → zero writes) | N/A in simulation |
| Audit ↔ resource reconciliation | 6/6 matched |
| Translator equivalence | N/A in simulation |
| Convergence p95 (s) | 0.380 |
| Failure naming and alerts | N/A in simulation |
| Telemetry join (trace ↔ UI/resources) | Seeded correlation id present |
| Cold-read bring-up time | See docs/INTENT_TIER_OPS_READINESS.md |
| Health/readiness endpoints | 200/503 behaviour exercised in unit tests |
| Tier-absent gates | Verified in tier-absent CI job |
| Residual Claims | 0 |
| Provider selection boundary | N/A in simulation |
| Leaked Credentials | 0 |

## Evidence paths

- API sessions: agents/tests/simulation/results/api-sessions.jsonl
- Browser sessions: ui/tests/simulation/results/browser-sessions.jsonl
- Kubernetes evidence: agents/tests/simulation/evidence/kubernetes/
- Telemetry evidence: agents/tests/simulation/evidence/telemetry/ (includes trace.jsonl, metrics.jsonl, dashboard.json)

## Readiness and dependencies

- Readiness sign-off:
  - Decision: Go
  - Signed by: On‑call Operator
  - Date: 2026-09-02
  - Notes: Tier operates within lab headroom; degradations name themselves; backup/restore verified.
- Base-fabric dependency status:
  - Status update 2026-09-04: Type-2 and Type-5 origination are resolved on the
    clean 202505 image; the unwaived fabric gate passes (see
    `docs/FABRIC_BGP_EVPN_DEFERRED.md`).

## Summary

All simulated sessions completed successfully. Threshold assertions passed and reconciliation checks found no orphaned resources or claims. All base-fabric workloads remained Ready.
