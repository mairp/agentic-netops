# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

Unmet criteria and gaps:

- T027a — SRv6Service CRD scaffolding requires CR examples
  - The envtest uses config/samples/ainetops_v1alpha1_srv6service.yaml as the positive sample, but that file is not present in the grounding snapshot and not listed among “verified present” elisions. Without the actual example, this criterion is unclear.
  - NEEDS-GROUNDING:config/samples/ainetops_v1alpha1_srv6service.yaml

- T029a — Per-path OpenConfig-vs-SONiC register must be CI-checked to prevent regressions
  - While pkg/register/oc_vs_sonic.yaml and a validator (pkg/sdc/validate.go) exist, there is no independently observable evidence that CI or a make target actually runs this guard. No test or pipeline artifact was provided that fails when a rendered path is missing from the register.
  - Provide an independently runnable test or CI/make target that invokes ValidateSpecAgainstRegister on rendered output and fails on missing coverage, and show its presence in the repo.
  - NEEDS-GROUNDING:Makefile
  - NEEDS-GROUNDING:tests (name the exact test path that enforces the register coverage)

- T040 — Ordered finalization requires an integration effect witness
  - Code in controllers/sonicprovider/controller.go implements deletion ordering, but no integration-level, independently readable effect is shown. The witness must show, via a separate read path, that the owned SDC Config is deleted, the finalizer is removed, and durable evidence (e.g., a finalized-at annotation) exists on the owner. There is no kubectl/log evidence of a resource actually being finalized. Additionally, the spec calls for “release owned claims”; no evidence shows claim release behavior.
  - Provide kubectl outputs (or equivalent) before/after deletion proving the owned SDC Config was removed, the finalizer cleared, and the annotation written on the owner; also demonstrate any owned-claim release or justify if none are owned.

VERDICT 43a4445b1dd23d7c: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./controllers.sonicprovider.controller.metrics-tracing.slice.txt`) or state in your evidence that grounding cannot reach it:
- `controllers.sonicprovider.controller.metrics-tracing.slice.txt`
- `pkg.render.srv6.go.slice.txt`
- `pkg.sdc.validate.go.slice.txt`
