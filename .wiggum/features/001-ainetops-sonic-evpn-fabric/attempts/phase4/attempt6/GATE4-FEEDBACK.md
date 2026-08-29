# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

Unmet or unclear criteria and concrete gaps:

- T026a Scaffold the SRv6 service controller binary and reconciler
  - The code shows leader election, health/readiness, graceful shutdown, and a reconciler wired for SRv6Service. However, the acceptance also requires “the same pinned dependency set as T026.” There is no grounded evidence of the pinned dependency set for this binary.
  - NEEDS-GROUNDING: go.mod

- T029a Produce a per-path OpenConfig-vs-SONiC-native register for all rendered YANG paths; prefer OpenConfig where supported; record each native-path gap with justification and CI-check the register
  - The current register (pkg/register/oc_vs_sonic.yaml) is incomplete for the already implemented renderers. Missing entries include at least:
    - /network-instances/network-instance/protocols/bgp/neighbors (rendered by pkg/render/bgp.go)
    - /network-instances/network-instance/bridges (rendered by pkg/render/network.go)
    - /interfaces/interface[vtep] (rendered by pkg/render/network.go)
    - /sonic-srv6:sonic-srv6/MYSID (rendered by pkg/render/srv6.go)
  - Each native-path gap must include justification; entries above lack coverage entirely.
  - The CI guard test provided only asserts that a missing path fails but does not assert that the current set of rendered paths is fully registered and passes the guard. Add a positive coverage test that renders a representative spec (using current renderers) and verifies ValidateSpecAgainstRegister passes with the in-repo register.

- T034 [P] Implement VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, and egress End.DT46 renderers
  - Large portions are unimplemented:
    - L3VNI rendering: missing
    - Type-5 EVPN rendering: missing
    - Symmetric IRB rendering: missing
    - SRv6 behaviors beyond basic MySID/global: H.Encaps.Red, transit End, End.DT46, and ordered SID-list steering are missing
  - The evidence itself admits these are deferred. This criterion is not met.

- T035 Compose deterministic ordered output, stable generated names, canonical hashes, compatibility annotations, owner references, and minimal scoped paths
  - While pkg/render/canon.go and ownedConfigName() exist, there is no grounded evidence in the provider reconciler showing:
    - Composition of minimal scoped paths
    - Use of CanonicalHash to compute and set annotations[ainetops.dev/config-hash]
    - Setting owner references (e.g., via controller-runtime SetControllerReference)
  - NEEDS-GROUNDING: controllers/sonicprovider/controller.go

- T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails
  - pkg/sdc/offline.go exists, but there is no grounded call site in the provider reconciler proving it is invoked before SSA and that on failure no SDC Config mutation is emitted.
  - NEEDS-GROUNDING: controllers/sonicprovider/controller.go

- T037 Implement server-side apply with a dedicated field manager, explicit priority, operation, revertive, and deletion policies
  - There is no grounded evidence of a Patch/Apply call with PatchOptions{FieldManager: "ainetops-sonic-provider", Force: true}, nor of a $policy block in the SDC Config spec carrying priority/operation/revertive/deletionPolicy.
  - NEEDS-GROUNDING: controllers/sonicprovider/controller.go

- T038 Observe SDC Config/Target/Deviation status and propagate standard per-device and aggregate conditions plus Kubernetes Events
  - Although sdc/types.go defines status fields, there is no grounded reconciler logic showing:
    - Reading SDC Config status and mapping Ready/Deviation to per-device conditions
    - Emitting Kubernetes Events with stable reason codes
    - Wiring an EventRecorder from the manager
  - NEEDS-GROUNDING: controllers/sonicprovider/controller.go

- T039 Implement bounded backoff/jitter and terminal-vs-transient error classification
  - resultWithBackoff exists, and model.IsTerminal exists, but there is no grounded evidence showing the provider’s reconcile uses terminal vs transient classification to choose backoff behavior across its error paths (beyond deletion handling).
  - NEEDS-GROUNDING: controllers/sonicprovider/controller.go

- T040 Implement ordered finalization: delete owned SDC intent, confirm/timeout, release owned claims, and retain manual recovery evidence
  - Code shows deletion of owned SDC Config, independent GET confirmation, and finalized-at annotation. However, this is an integration obligation requiring an independently observable durable effect witness. No such test or effect-witness artifact is provided.
  - Provide an envtest/integration test demonstrating:
    - Finalizer presence
    - Delete flow that issues delete of SDC Config, independently confirms deletion via GET, records finalized-at evidence, and then removes the finalizer
  - NEEDS-GROUNDING: tests/envtest/provider_finalization_test.go

- T041 Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, load, and deploy the provider image inside Kind; verify Pods, Services, probes, RBAC, and absence of secret or high-cardinality metric labels
  - Explicitly marked “Pending” by proposer. This criterion is not met.

VERDICT 2d17649da74d212c: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./controllers.sonicprovider.controller.go.proof.txt`) or state in your evidence that grounding cannot reach it:
- `controllers.sonicprovider.controller.go.proof.txt`
- `pkg.sdc.validate.proof.txt`
