# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

Unmet or unclear criteria (name → gap and required proof/evidence):

- T029a — OpenConfig-vs-SONiC register and CI guard:
  - Gap: While pkg/sdc/validate.go provides a default embedded register and a ValidateSpecAgainstRegister guard, there is no grounded evidence of a CI check preventing regressions (e.g., a test or verify target that fails when rendered paths are missing from the register). Runtime guarding in the controller is not a CI register regression check.
  - Required: A reproducible CI/test or Make target that exercises ValidateSpecAgainstRegister against the set of rendered paths and fails on gaps, plus proof it runs in CI. Provide the specific file/target and a test that intentionally trips a missing-path case.
  - NEEDS-GROUNDING: Makefile
  - NEEDS-GROUNDING: .github/workflows/ (or other CI config that runs the guard)

- T034 — Implement VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, and egress End.DT46 renderers:
  - Gap: No grounded renderer implementation files or tests are shown. The model types exist (pkg/model/types.go), and controllers import pkg/render, but there is no visible implementation of the required renderers or golden/determinism tests proving them.
  - Required: Concrete renderer code files and tests covering these behaviors (e.g., EVPN/VRF/L2VNI/L3VNI/Type-5 and SRv6 MySID/SID-list/H.Encaps.Red/transit End/End.DT46) plus proof slices or golden outputs.
  - NEEDS-GROUNDING: pkg/render (specific files implementing EVPN/L2VNI/L3VNI/BGP/IRB/SRv6 behaviors)

- T035 — Deterministic ordered output, stable generated names, canonical hashes, compatibility annotations, owner references, minimal scoped paths:
  - Gap: The controller constants imply hash/ownership (annotation/fieldManager), but no grounded code shows canonical hash calculation, deterministic ordering of rendered output, stable name generation, or minimal scoped paths for SSA ownership. No golden/idempotence tests are provided to prove determinism and minimality.
  - Required: Show the exact code composing ordered, canonical output, computing and annotating a canonical hash, setting owner references, and limiting SSA field paths; include golden/idempotence tests.
  - NEEDS-GROUNDING: controllers/sonicprovider/controller.go (the SSA compose/apply section)
  - NEEDS-GROUNDING: tests/golden/… (or equivalent deterministic render tests)

- T037 — Server-side apply with dedicated field manager, explicit priority, operation, revertive, and deletion policies:
  - Gap: Evidence claims SSA with a dedicated field manager, but the grounded controller excerpt does not include the SSA Patch/Apply calls or any explicit priority/operation/revertive/deletion policy settings.
  - Required: Show the exact client.Apply or Patch calls with FieldOwner, Force, ApplyOptions (including field manager and any custom conflict/priority policies), revertive behavior, and deletion policy handling.
  - NEEDS-GROUNDING: controllers/sonicprovider/controller.go (lines covering SSA apply and policies)

- T038 — Observe SDC Config/Target/Deviation status and propagate standard per-device and aggregate conditions plus Kubernetes Events:
  - Gap: The envtest only validates condition propagation (Degraded and Ready). There is no grounded evidence of Kubernetes Events being recorded, nor aggregate conditions behavior beyond the single-device case. The reconciler defines a Recorder interface but the code that emits Eventf is not shown.
  - Required: Show the Eventf calls and a test that asserts Events are emitted with stable reasons. Provide aggregate condition handling if implemented, or explicitly scope and prove per-device propagation with Events.
  - NEEDS-GROUNDING: controllers/sonicprovider/controller.go (Event recording section)
  - NEEDS-GROUNDING: tests/envtest/… (an event assertion test)

- T041 — Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, load, and deploy provider image inside Kind using T023’s manifests; verify Pods, Services, probes, RBAC, and absence of secret/high-cardinality metric labels:
  - Gap: OTel tracer imports and a prometheus.Counter field are present, but there is no grounded code initializing and incrementing a bounded metric nor evidence of label cardinality control. More importantly, there is no evidence of building, loading, and deploying the provider image into Kind, nor verification of running Pods/Services/probes/RBAC and absence of sensitive/high-cardinality labels.
  - Required: Show the metric initialization/increment with bounded labels; and provide logs or kubectl outputs from a Kind deployment (per T023 manifests) verifying Pods/Services/probes/RBAC and a metric/label audit demonstrating no secrets or high-cardinality labels.
  - NEEDS-GROUNDING: controllers/sonicprovider/controller.go (metric initialization/increment)
  - NEEDS-GROUNDING: config/deploy/… (or Helm values) used to deploy
  - NEEDS-GROUNDING: proof of a Kind deployment run (kubectl get pods/services, metrics scrape snippet)

Notes on criteria already previously confirmed and unchanged (per harness pins): T026, T027, T028, T029, T030, T031, T032, T033, T036, T039, T040 are not re-rejected; current snapshot does not contradict them.

VERDICT 677e592a1cd2c15c: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./controllers.sonicprovider.controller.go.proof.txt`) or state in your evidence that grounding cannot reach it:
- `controllers.sonicprovider.controller.go.proof.txt`
