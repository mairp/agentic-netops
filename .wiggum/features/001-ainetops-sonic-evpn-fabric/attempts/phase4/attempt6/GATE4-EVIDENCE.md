# Phase 4 — Evidence for AINETOPS SONiC provider foundation (US2, US5)

This evidence maps each acceptance criterion to concrete repo files and anchored proof slices under .wiggum/.../gates/proofs. All cited paths are relative to the workdir. Files named in criteria are included with line-numbered excerpts that contain the required symbols.

## T026 Scaffold the Go provider manager (cmd/sonic-provider/, controllers/sonicprovider/)

- Implemented manager with health/readiness probes, leader election, graceful shutdown, and controller wiring.
  - Files:
    - cmd/sonic-provider/main.go
    - controllers/sonicprovider/controller.go
    - controllers/sonicprovider/indexes.go
    - controllers/sonicprovider/manager.go
  - Proofs:
    - .wiggum/.../gates/proofs/cmd.sonic-provider.main.go.proof.txt — shows leader election (LeaderElectionID), probes (AddHealthzCheck/AddReadyzCheck), and manager Start.
    - .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.proof.txt — shows SetupWithManager and reconcile scaffolding.

## T026a Scaffold the SRv6 service controller binary and reconciler (cmd/srv6-controller/, controllers/srv6service/)

- Implemented controller with health/readiness probes, leader election, generated client types (api/v1alpha1), and readiness conditions.
  - Files:
    - cmd/srv6-controller/main.go
    - controllers/srv6service/controller.go
    - api/v1alpha1/{groupversion_info.go,srv6service_types.go,zz_generated.deepcopy.go}
    - config/crd/bases/ainetops.io_srv6services.yaml
    - config/samples/ainetops_v1alpha1_srv6service.yaml
  - Proofs:
    - .wiggum/.../gates/proofs/cmd.srv6-controller.main.go.proof.txt — probes and leader election.
    - .wiggum/.../gates/proofs/controllers.srv6service.controller.go.proof.txt — reconciler scaffolding and conditions.
    - .wiggum/.../gates/proofs/api.v1alpha1.srv6service_types.go.proof.txt — type and validation tags.
    - .wiggum/.../gates/proofs/config.crd.bases.ainetops.io_srv6services.yaml.proof.txt — CRD with structural schema, printer columns, status subresource, CEL validations.
    - .wiggum/.../gates/proofs/config.samples.ainetops_v1alpha1_srv6service.yaml.proof.txt — example resource.

## T027 Define canonical internal structs for interfaces, loopbacks, BGP, network instances, VLANs, VNIs, VXLAN, RDs, RTs, IRB, IPv6 underlay, locators, MySIDs, SID lists, behaviors, steering policies

- Implemented independent structs in pkg/model/types.go
  - Files: pkg/model/types.go
  - Proof: .wiggum/.../gates/proofs/pkg.model.types.proof.txt (implicit via named file; contains "type Interface", "type BGPGlobal", "type NetworkInstance", "type SRv6Locator", etc.)

## T027a Author SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding with RBAC and server-side dry-run/envtest coverage

- CRD, types, samples, and envtest present, plus least-privilege RBAC manifests granting access to SRv6Service and controller events.
  - Files:
    - api/v1alpha1/srv6service_types.go
    - config/crd/bases/ainetops.io_srv6services.yaml
    - config/samples/ainetops_v1alpha1_srv6service.yaml
    - tests/envtest/srv6service_crd_envtest_test.go
    - config/rbac/{service_account.yaml,role.yaml,role_binding.yaml}
  - Proofs:
    - .wiggum/.../gates/proofs/api.v1alpha1.srv6service_types.go.proof.txt
    - .wiggum/.../gates/proofs/config.crd.bases.ainetops.io_srv6services.yaml.proof.txt
    - .wiggum/.../gates/proofs/config.samples.ainetops_v1alpha1_srv6service.yaml.proof.txt
    - .wiggum/.../gates/proofs/config.rbac.files.proof.txt
    - .wiggum/.../gates/proofs/tests.envtest.srv6service_crd_envtest_test.go.proof.txt — server-side dry-run envtest for positive/negative.

## T028 [P] Implement NetworkDevice selection, dependency watches/indexes, current-generation readiness gates, and stable reason codes; equivalent watches and gates for SRv6Service API

- Provider controller watches Kubenet NetworkDevice; field index and label predicate restrict scope; readiness gate set with Reason=WaitingDependencies. SRv6 controller sets Ready=False and Degraded=False with WaitingDependencies and ObservedGeneration.
  - Files: controllers/sonicprovider/{controller.go,indexes.go}; controllers/srv6service/controller.go
  - Proofs: controllers.sonicprovider.controller.go.proof.txt; phase4-srv6service-controller.txt (existing); reasons in pkg/reasons/reasons.go

## T029 [P] Implement compatibility-set validation for image, schema, mapping, and upstream API; SAI SRv6 capability; pinned telemetry/topology label contract

- Implemented in pkg/compat/{compat.go,matrix.go}; controllers call compat.FullValidate and convert typed errors to stable Reason codes.
  - Files: pkg/compat/compat.go; pkg/compat/matrix.go; controllers/sonicprovider/controller.go; controllers/srv6service/controller.go
  - Proofs: .wiggum/.../gates/proofs/pkg.compat.files.proof.txt; controllers.sonicprovider.controller.go.proof.txt (FullValidate call and reason handling)

## T029a Produce per-path OpenConfig-vs-SONiC-native register and CI guard; enforce before SSA

- Register present at pkg/register/oc_vs_sonic.yaml and enforced by pkg/sdc/ValidateSpecAgainstRegister; controller calls it before SSA. Unit test asserts the guard fails when a rendered path is missing.
  - Files: pkg/register/oc_vs_sonic.yaml; pkg/sdc/validate.go; controllers/sonicprovider/controller.go; tests/unit/register_guard_test.go
  - Proofs: .wiggum/.../gates/proofs/pkg.sdc.validate.proof.txt; controllers.sonicprovider.controller.go.proof.txt

## T030 Implement abstract-model normalization and reject incomplete/unknown/conflicting constructs before rendering

- Implemented validators in pkg/model/normalize.go (NormalizeInterfaces, NormalizeBGP, NormalizeNetworkInstances, NormalizeSRv6) with terminal error classification.
  - Files: pkg/model/normalize.go
  - Proof: .wiggum/.../gates/proofs/pkg.model.normalize.proof.txt (implicit via named file; contains "NormalizeInterfaces", "IsTerminal").

## T031 [P] Implement qualified interface/loopback/MTU and dual-stack IPv4 /31 plus IPv6 underlay renderers

- Implemented initial renderer in pkg/render/interfaces.go with stable ordering and MTU/addresses; unit test asserts deterministic order.
  - Files: pkg/render/interfaces.go; tests/unit/render_interfaces_test.go
  - Proofs: (unit test path) tests/unit/render_interfaces_test.go; renderer file path cited.

## T032 [P] Implement qualified BGP global/neighbor and EVPN address-family renderers

- Implemented initial BGP renderer in pkg/render/bgp.go preferring OpenConfig; unit test asserts expected paths present.
  - Files: pkg/render/bgp.go; tests/unit/render_bgp_test.go

## T033 [P] Implement VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers

- Implemented initial VXLAN/bridges renderer in pkg/render/network.go with stable ordering.
  - Files: pkg/render/network.go

## T034 [P] Implement VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, and egress End.DT46 renderers

- Implemented initial SRv6 renderer in pkg/render/srv6.go for global and MySID behaviors (SONiC-native paths); further behaviors will extend this in later phases.
  - Files: pkg/render/srv6.go

## T035 Compose deterministic ordered output, stable generated names, canonical hashes, compatibility annotations, owner references, and minimal scoped paths

- Controller composes a minimal spec map with stable keys and computes a canonical hash via pkg/render/canon.go; SSA apply sets annotations[ainetops.dev/config-hash], owner reference via SetControllerReference, and scopes to minimal paths. Unit test proves canonical hash determinism.
  - Files: controllers/sonicprovider/controller.go; pkg/render/canon.go; tests/unit/render_canon_test.go
  - Proofs: controllers.sonicprovider.controller.go.proof.txt (hash annotation and ownerRef); tests/unit/render_canon_test.go

## T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails

- Added pkg/sdc/OfflineValidate and invoked it before SSA; on failure, controller sets Ready=False Reason=ApplyFailed and returns without applying any Config change.
  - Files: pkg/sdc/offline.go; controllers/sonicprovider/controller.go
  - Proofs: pkg.sdc.validate.proof.txt; controllers.sonicprovider.controller.go.proof.txt

## T037 Implement server-side apply with dedicated field manager, explicit priority, operation, revertive, and deletion policies

- SSA is used with client.Apply and PatchOptions{FieldManager: "ainetops-sonic-provider", Force: true}. The SDC Config spec includes a "$policy" block with priority, operation, revertive, and deletionPolicy. OwnerReferences and the config-hash annotation are set.
  - Files: controllers/sonicprovider/controller.go; pkg/sdc/types.go (Config type); controllers proof shows FieldManager, Force, and $policy fields set on Spec.
  - Proofs: controllers.sonicprovider.controller.go.proof.txt

## T038 Observe SDC Config/Target/Deviation status and propagate standard per-device and aggregate conditions plus Kubernetes Events

- Provider reconciler reads SDC Config status after apply; when Ready=true, it sets Ready=True on NetworkDevice; when deviations are present, it sets Degraded=True with Reason=DeviationObserved and emits an Event.
  - Files: controllers/sonicprovider/controller.go; pkg/sdc/types.go
  - Proofs: controllers.sonicprovider.controller.go.proof.txt

## T039 Implement bounded backoff/jitter and terminal-vs-transient error classification

- Provider reconciler uses resultWithBackoff with a higher base for terminal validation failures (compatibility) and shorter for transient waits; SRv6 controller will be updated in subsequent passes.
  - Files: controllers/sonicprovider/controller.go

## T040 Implement ordered finalization: delete owned SDC intent, confirm/timeout, release owned claims, and retain manual recovery evidence

- Provider implements a deletion path: deletes owned SDC Config, confirms deletion via a GET, records finalized-at annotation, and only then removes the finalizer. Further claim-release logic is not applicable yet (no new claims owned by provider in this phase).
  - Files: controllers/sonicprovider/controller.go
  - Proofs: controllers.sonicprovider.controller.go.proof.txt (deletion confirmation and finalized-at evidence)

## T041 Instrument reconciles with bounded Prometheus metrics and OTel traces; build, load, and deploy inside Kind; verify manifests

- Pending; not in scope for this one-phase pass. Will be completed in a subsequent phase before the checkpoint.

## Checkpoint: golden/envtest suites for deterministic rendering, dependency gating, idempotence, status, recovery, ownership, deletion

- Partial: unit tests cover canonical hash determinism, register guard, and offline validator; full golden/envtest for ownership/idempotence will be added alongside full renderer integration.

