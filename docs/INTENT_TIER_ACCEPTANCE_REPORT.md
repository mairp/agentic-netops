# Intent Tier Acceptance Report

This report aggregates simulation outcomes for Phase 11.

## SC-001 through SC-016 Results (T465)

| Code | Description | Result |
|---|---|---|
| SC-001 | Tier bring-up success (from clean) | See docs/INTENT_TIER_OPS_READINESS.md (SC-011 timing) |
| SC-002 | First-pass interpretation accuracy | 100.00% |
| SC-003 | Unsupported-refusal rate | 0.00% |
| SC-004 | Direct-action refusal rate | 0.00% |
| SC-005 | Idempotence (unchanged intent → zero writes) | N/A in simulation |
| SC-006 | Audit ↔ resource reconciliation | 6/6 matched |
| SC-007 | Translator equivalence | N/A in simulation |
| SC-008 | Convergence p95 (s) | 0.380 |
| SC-009 | Failure naming and alerts | N/A in simulation |
| SC-010 | Telemetry join (trace ↔ UI/resources) | Seeded correlation id present |
| SC-011 | Cold-read bring-up time | See docs/INTENT_TIER_OPS_READINESS.md |
| SC-012 | Health/readiness endpoints | 200/503 behaviour exercised in unit tests |
| SC-013 | Tier-absent gates | Verified in tier-absent CI job |
| SC-014 | Residual Claims | 0 |
| SC-015 | Provider selection boundary | N/A in simulation |
| SC-016 | Leaked Credentials | 0 |

## Evidence paths (T466)

- API sessions: agents/tests/simulation/results/api-sessions.jsonl
- Browser sessions: ui/tests/simulation/results/browser-sessions.jsonl
- Kubernetes evidence: agents/tests/simulation/evidence/kubernetes/
- Telemetry evidence: agents/tests/simulation/evidence/telemetry/ (includes trace.jsonl, metrics.jsonl, dashboard.json)

## Readiness and dependencies (T467)

- Readiness sign-off (T426):
  - Decision: Go
  - Signed by: On‑call Operator (SC‑011)
  - Date: 2026-09-02
  - Notes: Tier operates within lab headroom; degradations name themselves; backup/restore verified.
- Feature-001 D-A status (T422):
  - Status: Type-2 origination RESOLVED; Type-5 BLOCKED by image defect; acceptance relies on documented waiver (see docs/FABRIC_BGP_EVPN_DEFERRED.md lines 41–73).

## Summary (T468)

All simulated sessions completed successfully. Threshold assertions passed and reconciliation checks found no orphaned resources or claims. Feature-001 remained Ready.
