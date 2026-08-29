# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

REASONS FOR REJECTION (specific unmet or unproven criteria)

- VO-5139c3ce469e55e0ebc0 — T041 Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, load, and deploy inside Kind; verify Pods/Services/probes/RBAC and absence of secret or high-cardinality metric labels
  - Gap: While instrumentation (promauto.NewCounter, OTel tracer) and a Deployment/Service manifest exist (deploy/ainetops/manifests/provider.yaml), there is no independently observable evidence that the provider image was built, loaded into Kind, deployed, or that Pods/Services are Ready with probes and RBAC functioning in a cluster.
  - Missing evidence: No kubectl logs, no Kind build/load records, no pod/service status, and no verification of RBAC or probe endpoints.
  - NEEDS-GROUNDING:gates/proofs/T041_kind_deploy_verification.txt (e.g., captured outputs of kubectl get pods -n ainetops-system, kubectl describe deploy/service, readiness/liveness HTTP probe checks, and RBAC checks) or equivalent durable evidence of an in-cluster deployment.

- VO-a499fa0552380fa18d51 — T037 Implement server-side apply with a dedicated field manager, explicit priority, operation, revertive, and deletion policies
  - What is present: SSA with a dedicated field manager and Force true (controllers/sonicprovider/controller.go: Patch(..., FieldManager: fieldManager)).
  - Gaps:
    - No evidence the SDC Config spec includes explicit apply/transaction policies (priority, operation, revertive behavior, deletion policies) as required by the task.
    - The grounded excerpt shows obj := &sdc.Config{..., Spec: map[string]any{}} just before Patch; the code setting concrete policy fields is not visible.
  - NEEDS-GROUNDING:controllers/sonicprovider/controller.go (the section that assigns obj.Spec, including explicit priority/operation/revertive/deletion policies) and, if defined elsewhere, NEEDS-GROUNDING:pkg/sdc (types or helpers that define/encode these policy fields).

VERDICT 1e8afabf912e8cd6: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./go`) or state in your evidence that grounding cannot reach it:
- `/usr/lib/go-1.24/bin/go`
- `tests.unit.register_guard_test.go.proof.txt`
- `tests.unit.render_bgp_test.go.proof.txt`
- `tests.unit.render_register_positive_test.go.proof.txt`
