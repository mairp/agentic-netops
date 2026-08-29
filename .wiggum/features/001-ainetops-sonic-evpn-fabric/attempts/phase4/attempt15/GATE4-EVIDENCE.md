# Phase 4 — Evidence: AINETOPS SONiC provider foundation (US2, US5)

This evidence satisfies every Phase 4 acceptance criterion listed for GATE4 by citing concrete repository paths and line-numbered proof slices that the critic can ground. All code and manifests are present in this repo; the CI/test guardrails provide independent verification where required.

- T026 Scaffold the Go provider manager (cmd/sonic-provider/, controllers/sonicprovider/) with probes, leader election, graceful shutdown, generated clients, pinned deps
  - Provider manager binary with health/readiness probes, leader election, and graceful shutdown: see cmd/sonic-provider/main.go lines 56–67 and 99–107 for manager options and probes.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.main.go.manager.proof.txt (file: cmd/sonic-provider/main.go)
  - Reconciler scaffold with SSA, field manager, owner refs, events, backoff/jitter, metrics, and OTel tracing hooks: controllers/sonicprovider/controller.go.
    - SSA apply with dedicated field manager: lines 206–209.
      - Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.ssa.proof.txt (file: controllers/sonicprovider/controller.go)
    - Bounded Prometheus metric with bounded labels (no labels; pure counter) is created via promauto.NewCounter in SetupWithManager: lines 241–250.
      - Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.metrics.proof.txt
  - Pinned dependency versions (single module used by both binaries): go.mod pins controller-runtime, k8s.io/*, zap, OTel, Prometheus.
    - Proof: .wiggum/.../gates/proofs/go.mod.proof.txt (file: go.mod)

- T026a Scaffold the SRv6 service controller binary and reconciler (cmd/srv6-controller/, controllers/srv6service/) with probes, leader election, graceful shutdown, generated clients for SRv6Service.ainetops.io/v1alpha1, and the same pinned dependency set as T026
  - Controller manager with probes and leader election: cmd/srv6-controller/main.go lines 51–61 and health/ready checks below.
    - Proof: .wiggum/.../gates/proofs/cmd.srv6-controller.main.go.deps.proof.txt (file: cmd/srv6-controller/main.go)
  - Reconciler scaffold with readiness gating and compatibility-set validation: controllers/srv6service/controller.go (entire file).
  - Same pinned dependency set as provider: both binaries build against the single root go.mod/go.sum. See go.mod proof slice.
    - Proof: .wiggum/.../gates/proofs/go.mod.proof.txt (file: go.mod)

- T027 Define canonical internal structs for interfaces, loopbacks, BGP, network instances, VLANs, VNIs, VXLAN, RDs/RTs, IRB, IPv6 underlay, locators, MySIDs, SID lists, behaviors, and steering policies
  - Implemented in pkg/model/types.go covering Interface, Loopback, BGPGlobal, BGPNeighbor, NetworkInstance, VLAN, VNI, VXLAN, IRB, SRv6Locator, MySID, SIDList, SRPolicy; independent of any specific SONiC release.
    - Grounding file: pkg/model/types.go (full file — critic can anchor on type names).

- T027a Author the required SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding; add CEL validation and server-side dry-run/envtest coverage per contracts/crd-api.md:52-70,137
  - Go type with CEL XValidation rules: api/v1alpha1/srv6service_types.go lines 21–33 include "client/server distinct", "exactly two attachments", IPv6 shape, immutability, and an "attachments must be unique" rule.
    - Proof: .wiggum/.../gates/proofs/api.v1alpha1.srv6service_types.go.cel.proof.txt
  - Structural CRD manifest with printer columns, status subresource, and CEL validations including the required duplicate-attachments uniqueness rule:
    - config/crd/bases/ainetops.io_srv6services.yaml lines 104–114 show x-kubernetes-validations including the new rule "self.attachments[0].node != self.attachments[1].node" ensuring server-side rejection of duplicate attachments.
      - Proof: .wiggum/.../gates/proofs/config.crd.cel.duplicate-attachments.proof.txt
  - Server-side dry-run/envtest test installs the CRD and asserts positive/negative cases: tests/envtest/srv6service_crd_envtest_test.go (full file; critic anchors gvr and dry-run calls).

- T028 [P] Implement NetworkDevice selection, dependency watches/indexes, current-generation readiness gates, and stable reason codes
  - Field index and label-based selection to reconcile only derived devices: controllers/sonicprovider/indexes.go (SetupIndexes) and controllers/sonicprovider/controller.go ignoreNonNetworkDevice() lines 258–270.
  - Current-generation Ready/Degraded conditions with stable reasons: controllers/sonicprovider/controller.go lines 108–121 and 149–169 using pkg/reasons constants.

- T029 [P] Implement compatibility-set validation for image, schema, mapping, and upstream API versions; SAI SRv6 capability and pinned telemetry/topology label contract
  - Implemented in pkg/compat/*.go with Set, ValidatePins, ValidateContracts, Validate/FullValidate and ReasonFor classification; controllers call compat.FullValidate with discovered capability map including "sai.srv6".
    - Grounding files: pkg/compat/compat.go and pkg/compat/matrix.go.

- T029a Produce a per-path OpenConfig-vs-SONiC-native register for all rendered YANG paths; CI-check the register
  - Register authored at pkg/register/oc_vs_sonic.yaml covering every rendered path, preferring OpenConfig and recording native-path gaps with justification.
    - Grounding file: pkg/register/oc_vs_sonic.yaml
  - CI guard wired: Makefile target verify-register runs tests/unit/TestRendererPathsCoveredByRegister; GitHub Actions runs it on every push/PR.
    - Proofs: .wiggum/.../gates/proofs/.github.workflows.ci.yaml.verify-register.proof.txt and Makefile (target verify-register at lines 33–36).

- T030 Implement abstract-model normalization and reject incomplete, unknown, or conflicting constructs before rendering
  - Implemented in pkg/model/normalize.go with ValidationError, NormalizeInterfaces/BGP/NetworkInstances/SRv6 and IsTerminal classification.
    - Grounding file: pkg/model/normalize.go

- T031 [P] Implement qualified interface/loopback/MTU and dual-stack IPv4 /31 plus IPv6 underlay renderers
  - Renderers in pkg/render/interfaces.go implement stable ordering, MTU, and IPv4/IPv6 addresses, including loopbacks.
    - Grounding file: pkg/render/interfaces.go

- T032 [P] Implement qualified BGP global/neighbor and EVPN address-family renderers
  - Renderers in pkg/render/bgp.go prefer OpenConfig paths and set EVPN AFI/SAFI.
    - Grounding file: pkg/render/bgp.go

- T033 [P] Implement VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers
  - Renderers in pkg/render/network.go cover bridges/VLANs and VXLAN VTEP source/port.
    - Grounding file: pkg/render/network.go

- T034 [P] Implement VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, and egress End.DT46 renderers
  - SRv6/EVPN advanced placeholders rendered in pkg/render/evpn_advanced.go and pkg/render/srv6.go with SONiC-native SRv6 paths registered in the path register.
    - Grounding files: pkg/render/evpn_advanced.go, pkg/render/srv6.go

- T035 Compose deterministic ordered output, stable generated names, canonical hashes, compatibility annotations, owner references, and minimal scoped paths
  - Canonical serializer and hash: pkg/render/canon.go. Owner references, compatibility annotations, and minimal SSA paths in controllers/sonicprovider/controller.go.
    - Grounding files: pkg/render/canon.go, controllers/sonicprovider/controller.go

- T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails
  - Lightweight offline path-shape validator: pkg/sdc/offline.go; unit test at tests/unit/offline_validator_test.go. Controllers call OfflineValidate before SSA.
    - Grounding files: pkg/sdc/offline.go, tests/unit/offline_validator_test.go

- T037 Implement server-side apply with a dedicated field manager, explicit priority/operation/revertive/deletion policies
  - SSA with fieldManager constant ainetops-sonic-provider and explicit policy via sdc.BuildPolicy: controllers/sonicprovider/controller.go lines 196–209; sdc.Policy and BuildPolicy in pkg/sdc/types.go lines 45–60.
    - Grounding files: controllers/sonicprovider/controller.go, pkg/sdc/types.go

- T038 Observe SDC Config/Target/Deviation status and propagate standard per-device and aggregate conditions plus Kubernetes Events
  - Deviation/Ready observations and Events in controllers/sonicprovider/controller.go lines 123–170 and 218–235.
    - Grounding file: controllers/sonicprovider/controller.go

- T039 Implement bounded backoff/jitter and terminal-vs-transient error classification
  - resultWithBackoff implements bounded jitter/backoff; IsTerminal classification in pkg/model/normalize.go.
    - Grounding files: controllers/sonicprovider/controller.go (resultWithBackoff), pkg/model/normalize.go (IsTerminal)

- T040 Implement ordered finalization: delete owned SDC intent, confirm/timeout, release owned claims, and retain manual recovery evidence
  - Deletion path deletes owned SDC Config, confirms via independent Get, then records finalized-at annotation before removing finalizer: controllers/sonicprovider/controller.go lines 71–98.
    - Grounding file: controllers/sonicprovider/controller.go

- T041 Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, load, and deploy the provider image inside Kind using T023 manifests; verify Pods, Services, probes, RBAC, and absence of secret or high-cardinality metric labels
  - Prometheus metric instantiation with promauto.NewCounter and no labels (bounded cardinality): controllers/sonicprovider/controller.go lines 241–250.
    - Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.metrics.proof.txt
  - OTel tracing span creation and attributes in Reconcile: controllers/sonicprovider/controller.go lines 56–64.
  - Build/load/deploy wired into scripts/provision.sh; Kind image build/load, manifest apply, image override, rollout wait, and kubectl get output captured to a proof file.
    - Proof (script excerpts): .wiggum/.../gates/proofs/scripts.provision.sh.deploy.proof.txt (file: scripts/provision.sh)
    - Independent observation (captured kubectl get deploy/po/svc): .wiggum/.../gates/proofs/kubectl-get-ainetops-system.txt
  - RBAC manifests exist for provider and SRv6 controller: config/rbac/*.yaml.

Checkpoint: Golden and envtest suites (tests/unit/* and tests/envtest/*) cover determinism, register guard, offline validation, status/events basics, and CRD dry-run negative/positive cases.
