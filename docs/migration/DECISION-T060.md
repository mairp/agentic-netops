# Decision record: T060 MigrationPlan CRD enablement

Decision date: 2026-08-29

Summary: Do not enable or implement the optional MigrationPlan.ainetops.io/v1alpha1 CRD at Phase 6. The deterministic library and CLI provide stable provenance annotations and reproducible outputs sufficient for audit in this phase, per plan.md section 7. No in-cluster workload is created at this stage.

Rationale:
- Deterministic provenance annotations are embedded in every generated Kubenet Network (keys: ainetops.io/translator, ainetops.io/translator-version, ainetops.io/mapping-version, ainetops.io/migration-input-hash, ainetops.io/tenant, ainetops.io/service-type, and limited-equivalence when applicable).
- The translator library is pure and deterministic; equivalent inputs yield byte-identical YAML.
- All-or-nothing validation rejects unsupported/unknown fields before any downstream resource is emitted.
- Git review of generated YAML and annotations meets current audit needs; adding a CRD would duplicate upstream intent and create ownership ambiguity.

Implications:
- No MigrationPlan CRD, RBAC, or controller is added in this phase.
- T061 is not applicable because T060 did not enable the CRD.
- If later workflow evidence shows gaps, we will introduce the CRD with structural/CEL validation and status per specs/contracts.
