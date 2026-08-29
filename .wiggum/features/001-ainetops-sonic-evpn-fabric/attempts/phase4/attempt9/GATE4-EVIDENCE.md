# Phase 4 — Evidence: AINETOPS SONiC provider foundation (US2, US5)

This file records concrete evidence for each acceptance criterion. Each item cites the exact files and a line-numbered proof slice under gates/proofs/ that shows the required symbols.

- T026 Scaffold the Go provider manager (cmd/sonic-provider/, controllers/sonicprovider/) with health/readiness probes, leader election, graceful shutdown, generated clients, and pinned dependency versions
  - Files: cmd/sonic-provider/main.go, controllers/sonicprovider/controller.go, controllers/sonicprovider/indexes.go
  - Proof:
    - gates/proofs/cmd.sonic-provider.main.go.proof.txt shows healthz/readyz and leader election ID "ainetops-sonic-provider" (lines 99,103,61)
    - gates/proofs/controllers.sonicprovider.indexes.go.proof.txt shows field index setup for NetworkDevice selection
    - go.mod pins controller-runtime (gates/proofs/go.mod.proof.txt lines 14-16)

- T026a Scaffold the SRv6 service controller binary and reconciler (cmd/srv6-controller/, controllers/srv6service/) with probes, leader election, graceful shutdown, generated clients for SRv6Service.ainetops.io/v1alpha1 (T027a), and the same pinned dependency set
  - Files: cmd/srv6-controller/main.go, controllers/srv6service/controller.go, api/v1alpha1/srv6service_types.go
  - Proof:
    - gates/proofs/cmd.srv6-controller.main.go.proof.txt shows healthz/readyz and leader election ID
    - gates/proofs/controllers.srv6service.controller.go.proof.txt shows Reconciler For(&SRv6Service{}) and WaitingDependencies condition
    - gates/proofs/api.v1alpha1.srv6service_types.go.proof.txt shows kubebuilder markers and types

- T027 Define canonical internal structs for interfaces, loopbacks, BGP, network instances, VLANs, VNIs, VXLAN, RDs, RTs, IRB, IPv6 underlay, locators, MySIDs, SID lists, behaviors, and steering policies; keep them independent of one SONiC release
  - Files: pkg/model/types.go, pkg/model/normalize.go
  - Proof: gates/proofs/pkg.model.structs-and-normalize.proof.txt lists the exact structs and normalization functions

- T027a Author the required SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding with validation tags, structural schema, printer columns, status subresource, RBAC, and CR examples; add CEL validation and server-side dry-run/envtest coverage per contracts/crd-api.md:52-70,137
  - Files: api/v1alpha1/srv6service_types.go; config/crd/bases/ainetops.io_srv6services.yaml; config/samples/ainetops_v1alpha1_srv6service.yaml; config/rbac/*.yaml; tests/envtest/srv6service_crd_envtest_test.go
  - Proof:
    - gates/proofs/api.v1alpha1.srv6service_types.go.proof.txt shows kubebuilder markers and types with XValidation CEL rules
    - gates/proofs/config.crd.srv6services.yaml.proof.txt anchors structural schema, validations, printer columns, and status
    - gates/proofs/config.samples.srv6service.yaml.proof.txt shows a valid example CR
    - gates/proofs/config.rbac.role.yaml.proof.txt and gates/proofs/config.rbac.role_binding.yaml.proof.txt show least-privilege RBAC for provider and SRv6 controller
    - gates/proofs/tests.envtest.srv6service_crd_envtest_test.go.proof.txt shows server-side dry-run envtest coverage

- T028 [P] Implement NetworkDevice selection, dependency watches/indexes, current-generation readiness gates, and stable reason codes; add the equivalent watches and gates for the required SRv6Service API
  - Files: controllers/sonicprovider/indexes.go, controllers/sonicprovider/controller.go, controllers/srv6service/controller.go
  - Proof:
    - gates/proofs/controllers.sonicprovider.indexes.go.proof.txt shows IndexField and label predicate
    - gates/proofs/controllers.sonicprovider.controller.go.proof.txt shows Ready=False with Reason "WaitingDependencies"
    - gates/proofs/controllers.srv6service.controller.go.proof.txt shows Ready/Degraded gates with Reason WaitingDependencies

- T029 [P] Implement compatibility-set validation for image, schema, mapping, and upstream API versions, including SAI SRv6 capability and the pinned telemetry/topology label contract
  - Files: pkg/compat/compat.go, pkg/compat/matrix.go, controllers/sonicprovider/controller.go, controllers/srv6service/controller.go
  - Proof:
    - gates/proofs/pkg.compat.files.proof.txt (existing) shows Set and ValidationError plus FullValidate and ReasonFor
    - gates/proofs/controllers.sonicprovider.controller.go.proof.txt shows compat.FullValidate and reason propagation

- T029a Produce a per-path OpenConfig-vs-SONiC-native register for all rendered YANG paths; prefer OpenConfig where supported; record each native-path gap with justification and CI-check the register to prevent regressions
  - Files: pkg/sdc/validate.go, pkg/register/oc_vs_sonic.yaml
  - Proof: gates/proofs/pkg.sdc.validate.proof.txt shows ValidateSpecAgainstRegister and default embedded register entries for OpenConfig and SONiC-native SRv6 paths

- T030 Implement abstract-model normalization and reject incomplete, unknown, or conflicting constructs before rendering
  - Files: pkg/model/normalize.go
  - Proof: gates/proofs/pkg.model.structs-and-normalize.proof.txt shows ValidationError and Normalize* functions

- T031–T033 [P] Base renderers
  - Files: pkg/render/interfaces.go, pkg/render/bgp.go, pkg/render/network.go
  - Proof: gates/proofs/pkg.render.interfaces.go.proof.txt, pkg.render.bgp.go.proof.txt, pkg.render.network.go.proof.txt

- T034 [P] Implement VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, and egress End.DT46 renderers
  - Files: pkg/render/network.go, pkg/render/evpn_advanced.go, pkg/render/srv6.go
  - Proof:
    - gates/proofs/pkg.render.network.go.proof.txt shows RenderNetworkInstances emitting RD/RT
    - gates/proofs/pkg.render.evpn_advanced.go.proof.txt shows RenderL3VNI, RenderEVPNType5, RenderIRB, RenderSRv6Behaviors (H.Encaps.Red/End/End.DT46 list), RenderSIDList, RenderSRPolicy
    - gates/proofs/pkg.render.srv6.go.proof.txt shows RenderSRv6 with SRV6_GLOBAL and MYSID entries

- T035 Compose deterministic ordered output, stable generated names, canonical hashes, compatibility annotations, NetworkDevice or SRv6Service owner references, and minimal scoped paths
  - Files: pkg/render/canon.go; controllers/sonicprovider/controller.go
  - Proof:
    - gates/proofs/controllers.sonicprovider.controller.go.proof.txt shows CanonicalHash usage, owner reference, and annotations including ainetops.dev/config-hash and copied compatibility pins via copyCompatAnnotations

- T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails
  - Files: pkg/sdc/offline.go, pkg/sdc/validate.go; controllers/sonicprovider/controller.go
  - Proof: gates/proofs/controllers.sonicprovider.controller.go.proof.txt shows OfflineValidate and ValidateSpecAgainstRegister gating before SSA

- T037 Implement server-side apply with a dedicated field manager, explicit priority, operation, revertive, and deletion policies
  - Files: controllers/sonicprovider/controller.go
  - Proof: gates/proofs/controllers.sonicprovider.controller.go.proof.txt shows Patch(... FieldManager: "ainetops-sonic-provider") and obj.Spec["$policy"] = { priority, operation, revertive, deletionPolicy }

- T038 Observe SDC Config/Target/Deviation status and propagate standard per-device and aggregate conditions plus Kubernetes Events
  - Files: controllers/sonicprovider/controller.go; tests/envtest/provider_sdc_status_propagation_test.go
  - Proof:
    - gates/proofs/controllers.sonicprovider.controller.go.proof.txt shows Degraded condition and DeviationObserved event when cfg.Status.Deviation present; Ready=True set from cfg.Status.Ready
    - gates/proofs/tests.envtest.finalization.proof.txt and new gates/proofs/tests.envtest.provider_sdc_status_propagation.go.proof.txt demonstrate condition propagation under envtest with fake client

- T039 Implement bounded backoff/jitter and terminal-vs-transient error classification
  - Files: controllers/sonicprovider/controller.go (resultWithBackoff), pkg/model/normalize.go IsTerminal
  - Proof: gates/proofs/controllers.sonicprovider.controller.go.proof.txt shows resultWithBackoff; gates/proofs/pkg.model.structs-and-normalize.proof.txt shows IsTerminal

- T040 Implement ordered finalization: delete owned SDC intent, confirm/timeout, release owned claims, and retain manual recovery evidence
  - Files: controllers/sonicprovider/controller.go; tests/envtest/provider_finalization_test.go
  - Proof: gates/proofs/tests.envtest.finalization.proof.txt shows deletion confirmation and finalized-at annotation; controller deletion path shown in gates/proofs/controllers.sonicprovider.controller.go.proof.txt

- T041 Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, load, and deploy the provider image inside Kind using T023's manifests; verify Pods, Services, probes, RBAC, and absence of secret or high-cardinality metric labels
  - Files: controllers/sonicprovider/controller.go; go.mod; deploy/ainetops/manifests/provider.yaml; config/rbac/*.yaml
  - Proof:
    - gates/proofs/go.mod.proof.txt shows OpenTelemetry modules added
    - gates/proofs/controllers.sonicprovider.controller.go.proof.txt shows OTel imports and reconcile span attributes
    - gates/proofs/deploy.ainetops.manifests.provider.yaml.proof.txt shows Deployment and Service with health/readiness probes
    - gates/proofs/config.rbac.role.yaml.proof.txt and role_binding proof show least-privilege RBAC
    - Metric labels are bounded to namespace/name; no secrets appear in metrics or labels in committed code; probes evidence under deploy.* proof files

