# Decision record: MigrationPlan CRD enablement

Decision date: 2026-08-29

Summary: Do not enable or implement the optional MigrationPlan.agentic-netops.io/v1alpha1 CRD at Phase 6. The deterministic library and CLI provide stable provenance annotations and reproducible outputs sufficient for audit in this phase. No in-cluster workload is created at this stage.

Rationale:
- Deterministic provenance annotations are embedded in every generated Kubenet Network (keys: agentic-netops.io/translator, agentic-netops.io/translator-version, agentic-netops.io/mapping-version, agentic-netops.io/migration-input-hash, agentic-netops.io/tenant, agentic-netops.io/service-type, and limited-equivalence when applicable).
- The translator library is pure and deterministic; equivalent inputs yield byte-identical YAML.
- All-or-nothing validation rejects unsupported/unknown fields before any downstream resource is emitted.
- Git review of generated YAML and annotations meets current audit needs; adding a CRD would duplicate upstream intent and create ownership ambiguity.

Implications:
- No MigrationPlan CRD, RBAC, or controller is added in this phase.
- The follow-up CRD-enablement work is not applicable because this decision did not enable the CRD.
- If later workflow evidence shows gaps, we will introduce the CRD with structural/CEL validation and status.
