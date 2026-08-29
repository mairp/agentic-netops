# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

Unmet or unclear criteria

- T027a — SRv6Service CRD scaffolding requires RBAC manifests
  - Gap: No RBAC manifests were shown for the SRv6Service controller or its API access. The SPEC requires RBAC along with the CRD, printer columns, status, and examples.
  - Action: Provide the RBAC YAML (e.g., config/rbac/{role.yaml, role_binding.yaml, service_account.yaml}) granting the controller least-privilege access to SRv6Service and related resources, or show where these are generated and committed.
  - NEEDS-GROUNDING:config/rbac/

- T029 — Compatibility-set validation (image, schema, mapping, upstream API versions; SAI SRv6 capability; pinned telemetry/topology label contract)
  - Gap: Only a proof slice of pkg/compat/matrix.go was provided; the implementation details of FullValidate, ValidatePins, and ValidateContracts are not grounded. The controllers call compat.FullValidate, but without the actual code we cannot verify checks for image, schema, mapping, and upstream API versions or enforcement of the telemetry/topology label contract.
  - Action: Ground the full compat implementation and show controller paths wiring all checks and setting stable Reason codes (e.g., SchemaMismatch, CapabilityMissing).
  - NEEDS-GROUNDING:pkg/compat/compat.go
  - NEEDS-GROUNDING:pkg/compat/matrix.go

- T029a — Per-path OpenConfig-vs-SONiC-native register and CI guard
  - Gaps:
    - While pkg/register/oc_vs_sonic.yaml and sdc.ValidateSpecAgainstRegister exist, there is no grounded call site in the reconcile flow proving the register is enforced “before SSA” as claimed.
    - The “CI-check the register to prevent regressions” is not demonstrated (no test or linter tying rendered paths to the register).
  - Action: Show the exact call in the provider reconcile prior to apply, plus a CI test that enumerates rendered paths and fails on missing/unregistered entries.
  - NEEDS-GROUNDING:controllers/sonicprovider/controller.go
  - Provide a CI test (path and content) that asserts register coverage of all rendered paths.

- T031 — Qualified interface/loopback/MTU and dual-stack IPv4 /31 plus IPv6 underlay renderers
  - Gap: Renderers are not implemented; the evidence explicitly defers renderers to later passes.
  - Action: Implement and ground the renderers and associated tests.

- T032 — Qualified BGP global/neighbor and EVPN address-family renderers
  - Gap: Not implemented (deferred).
  - Action: Implement and ground the renderers and associated tests.

- T033 — VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers
  - Gap: Not implemented (deferred).
  - Action: Implement and ground the renderers and associated tests.

- T034 — VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, and egress End.DT46 renderers
  - Gap: Not implemented (deferred).
  - Action: Implement and ground the renderers and associated tests.

- T035 — Compose deterministic ordered output, stable generated names, canonical hashes, compatibility annotations, owner references, and minimal scoped paths
  - Gaps:
    - The reconcile file is truncated in the snapshot; the claimed canonical hash annotation, owner references, deterministic ordering, and minimal scoped paths are not independently observable.
    - Without T031–T034 renderers, deterministic composition across the full model is unproven; no golden tests showing ordering, idempotence, and hash stability were provided.
  - Action: Ground the complete reconcile code showing deterministic composition, stable name generation, canonical hashing, ownerRefs, and minimal scoped paths; add golden tests proving deterministic ordering and idempotence.
  - NEEDS-GROUNDING:controllers/sonicprovider/controller.go

- T036 — Integrate offline SDC/schema validation; emit no changed Config when validation fails
  - Gap: Only a register guard exists; no offline SDC schema validation integration is shown and no reconcile gating on its result is grounded.
  - Action: Integrate SDC’s offline validator and demonstrate that failed validation blocks any Config mutation; include tests.

- T037 — Server-side apply (SSA) with dedicated field manager, explicit priority, operation, revertive, and deletion policies
  - Gaps:
    - The SSA apply path (client.Apply or apply Patch with FieldManager) is not visible in the grounded code; the proof slice provided earlier does not show SSA.
    - No evidence of setting explicit SDC priority/operation/revertive/deletion policies on the Config spec.
    - OwnerReferences and the config-hash annotation are claimed but not grounded in code.
  - Action: Ground the exact SSA call (field manager name, force/patch type), show the SDC Config spec fields for priority/operation/revertive/deletion policies, and demonstrate ownerRefs and hash annotation on created/updated Configs.
  - NEEDS-GROUNDING:controllers/sonicprovider/controller.go
  - NEEDS-GROUNDING:pkg/sdc/* (types for Config and policy fields)

- T038 — Observe SDC Config/Target/Deviation status and propagate conditions/events
  - Gap: Not implemented; no code or tests showing observation of SDC status or propagation of per-device and aggregate conditions and Kubernetes Events.
  - Action: Implement watches/indexes for relevant SDC statuses, condition propagation, and Event emission; add tests.

- T039 — Bounded backoff/jitter and terminal-vs-transient error classification
  - Gaps:
    - resultWithBackoff implements bounded jitter, but terminal-vs-transient classification is not integrated with IsTerminal; the controllers never use such classification to choose retry strategy across error types.
    - SRv6 controller uses a fixed requeue and does not apply bounded backoff/jitter or classification.
  - Action: Wire model.IsTerminal (or equivalent) into reconcile error handling and use distinct backoff for terminal vs transient errors in both controllers; add tests demonstrating the behavior.

- T040 — Ordered finalization: delete owned SDC intent, confirm/timeout, release owned claims, and retain manual recovery evidence
  - Gaps:
    - The controller deletes the owned SDC Config and annotates finalized-at, but there is no confirmation/timeout loop to observe deletion through an independent read path.
    - No release of owned claims is implemented.
    - No independent effect witness (durable state or content hash) is provided as required by the effect-witness oracle.
  - Action: Implement confirmation/timeout semantics, release any owned KUID/other claims, and provide an integration test or log demonstrating the independent durable effect.

- T041 — Instrument reconciles with bounded Prometheus metrics and OTel traces; build, load, and deploy provider image inside Kind; verify Pods, Services, probes, RBAC, and absence of secret/high-cardinality metric labels
  - Gap: Not implemented; no metrics/tracing instrumentation or deployment verification evidence provided.
  - Action: Add instrumentation, integrate with the existing Kind manifests (T023), and provide verification output (kubectl get, metrics endpoints, probe status) demonstrating correctness.

- Checkpoint — Golden and envtest suites for deterministic rendering, dependency gating, idempotence, status, recovery, ownership, and deletion
  - Gap: Only CRD envtest exists; no golden tests or envtests cover rendering determinism, ownership, idempotence, recovery, or deletion semantics.
  - Action: Add the required test suites and ground their results.

VERDICT 66b0c9d391b06bbf: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./controllers.sonicprovider.controller.go.proof.txt`) or state in your evidence that grounding cannot reach it:
- `controllers.sonicprovider.controller.go.proof.txt`
