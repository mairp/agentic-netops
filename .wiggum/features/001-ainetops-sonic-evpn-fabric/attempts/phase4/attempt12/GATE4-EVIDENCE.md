Phase 4 — AINETOPS SONiC provider foundation (US2, US5)

Summary
- All Phase 4 tasks T026–T041 are implemented at the scaffold/validation level required by this phase. Controllers compile and tests pass. Proofs are staged under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ and reference exact files and symbols.
- Deterministic verification: go test ./... succeeds; log saved as gates/proofs/go_test_run.log.

Test run evidence
- Command: /usr/lib/go-1.24/bin/go test ./...
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/go_test_run.log

T026 Scaffold the Go provider manager (cmd/sonic-provider/, controllers/sonicprovider/)
- Implemented controller-runtime manager with health/readiness probes, leader election, graceful shutdown; provider reconciler with indexes, SSA apply, validation, metrics, traces.
- Files:
  - cmd/sonic-provider/main.go: NewManager options, LeaderElectionID, AddHealthzCheck/AddReadyzCheck, signal.NotifyContext.
    - Proof: gates/proofs/T026_provider_manager_main.txt (symbols: NewManager, LeaderElection, LeaderElectionID, AddHealthzCheck, AddReadyzCheck, MetricsBindAddress, signal.NotifyContext)
    - File path: cmd/sonic-provider/main.go
  - controllers/sonicprovider/controller.go: type Reconciler, Reconcile, resultWithBackoff, SetControllerReference, client.Apply with FieldManager, OfflineValidate, ValidateSpecAgainstRegister, CanonicalHash, promauto.NewCounter, otel.Tracer, Eventf.
    - Proof: gates/proofs/T026_provider_reconciler.txt
    - File path: controllers/sonicprovider/controller.go
  - controllers/sonicprovider/indexes.go: SetupIndexes for network.kubenet.dev/derived label.
    - Proof: gates/proofs/T028_indexes.txt (also cited below)
    - File path: controllers/sonicprovider/indexes.go
  - Pinned dependency versions recorded in go.mod and pkg/version/pins.go.
    - Proof: gates/proofs/T026_pins_gomod.txt
    - File path: go.mod

T026a Scaffold the SRv6 service controller binary and reconciler (cmd/srv6-controller/, controllers/srv6service/)
- Implemented separate manager with probes and leader election; reconciler scaffolding and status gating; uses generated clients for SRv6Service API.
- Files:
  - cmd/srv6-controller/main.go: NewManager, LeaderElectionID, AddHealthzCheck/AddReadyzCheck.
    - Proof: gates/proofs/T026a_srv6_controller_main.txt
    - File path: cmd/srv6-controller/main.go
  - controllers/srv6service/controller.go: type Reconciler, Ready/Degraded gating, compat.FullValidate, SetupWithManager.
    - Proof: gates/proofs/T026a_srv6_reconciler.txt
    - File path: controllers/srv6service/controller.go

T027 Define canonical internal structs (interfaces, loopbacks, BGP, network instances, VLANs, VNIs, VXLAN, RDs, RTs, IRB, IPv6 underlay, locators, MySIDs, SID lists, behaviors, steering policies)
- Implemented independent model types.
- File: pkg/model/types.go
  - Proof: gates/proofs/T027_model_structs.txt (symbols: type Interface, Loopback, BGPGlobal, BGPNeighbor, NetworkInstance, VLAN, VNI, VXLAN, IRB, SRv6Locator, MySID, SIDList, SRPolicy)

T027a Author required SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding
- Go types with validation tags; structural CRD with schema, printer columns, status subresource; RBAC; sample; envtest dry-run coverage.
- Files:
  - api/v1alpha1/srv6service_types.go, api/v1alpha1/groupversion_info.go
    - Proof: gates/proofs/T027a_crd_types.txt (symbols: SRv6Service, shortName, XValidation, PreserveUnknownFields=false note, Status, SRv6ServiceList, GroupVersion)
  - config/crd/bases/ainetops.io_srv6services.yaml
    - Proof: gates/proofs/T027a_crd_yaml.txt (symbols: CustomResourceDefinition, srv6services.ainetops.io, additionalPrinterColumns, x-kubernetes-validations, status: {}, preserveUnknownFields: false, enum: [ipv6])
  - deploy/rbac/srv6-crd-rbac.yaml (RBAC for CRD and SRv6Service)
    - Proof: gates/proofs/T027a_rbac.txt (symbols: ClusterRole, ainetops-srv6-controller-crd, customresourcedefinitions, ainetops.io, srv6services)
  - config/samples/ainetops_v1alpha1_srv6service.yaml
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config_samples_ainetops_v1alpha1_srv6service.yaml.proof.txt
  - tests/envtest/srv6service_crd_envtest_test.go
    - Proof: gates/proofs/T027a_envtest.txt (symbols: envtest, DryRun, Create, duplicate attachments, fail)

T028 [P] Implement NetworkDevice selection, dependency watches/indexes, readiness gates, stable reasons; add equivalent for SRv6Service
- Provider indexes and watch selection via network.kubenet.dev/derived; conditions and reasons; SRv6Service uses same reasons and gating.
- Files:
  - controllers/sonicprovider/indexes.go and controller.go
    - Proof: gates/proofs/T028_selection_watches.txt (symbols: WithEventFilter, ignoreNonNetworkDevice, network.kubenet.dev/derived)
  - pkg/reasons/reasons.go
    - Proof: gates/proofs/T028_reasons.txt (symbols: ReasonWaitingDependencies, ReasonApplySucceeded, ReasonApplyFailed, ReasonFinalizing, ReasonFinalized)

T029 [P] Implement compatibility-set validation for image, schema, mapping, and upstream API versions, including SAI SRv6 capability and pinned label contract
- Implemented compat.Set extraction/validation, pins/contracts checks, SRv6 capability gate; reasons returned for conditions.
- Files: pkg/compat/compat.go, pkg/compat/matrix.go
  - Proof: gates/proofs/T029_compat.txt (symbols: FullValidate, ValidatePins, ValidateContracts, FromAnnotations, ValidationError, ReasonFor, CapabilityMissing, SchemaMismatch)
  - Used in controllers/sonicprovider/controller.go and controllers/srv6service/controller.go (see T026, T026a proofs)

T029a Produce per-path OpenConfig-vs-SONiC register and CI guard (prefer OpenConfig; record native gaps)
- Authored register and wired a Makefile guard; unit tests ensure rendered paths covered; missing-path test enforces regression.
- Files:
  - pkg/register/oc_vs_sonic.yaml
    - Proof: gates/proofs/T029a_register.txt (symbols: entries:, /interfaces/interface, /network-instances/network-instance, /sonic-srv6:sonic-srv6/SRV6_GLOBAL, /sonic-srv6:sonic-srv6/MYSID, /sonic-srv6:sonic-srv6/SID_LIST, /sonic-srv6:sonic-srv6/POLICY, /sonic-srv6:sonic-srv6/BEHAVIORS)
  - Makefile verify-register target
    - Proof: gates/proofs/T029a_ci_guard.txt (symbol: go test ./tests/unit -run TestRendererPathsCoveredByRegister)
  - tests/unit/register_guard_test.go and tests/unit/render_register_positive_test.go
    - Proof: .wiggum/.../gates/proofs/tests.unit.register_guard_test.go.proof.txt and tests.unit.render_register_positive_test.go.proof.txt

T030 Implement abstract-model normalization and reject incomplete/unknown/conflicting constructs before rendering
- Integrated offline SDC schema/path validation and register coverage guard; rejects unregistered or malformed rendered paths.
- Files: pkg/sdc/offline.go, pkg/sdc/validate.go
  - Proof: gates/proofs/T030_sdc_validation.txt (symbols: OfflineValidate, invalid rendered path, ValidateSpecAgainstRegister, RegisterError, defaultRegister, unregistered rendered paths)
  - Used in controllers/sonicprovider/controller.go prior to SSA (see T036/T037 proof)

T031 [P] Implement qualified interface/loopback/MTU and dual-stack IPv4 /31 plus IPv6 underlay renderers
- RenderInterfaces outputs deterministic list including MTU and both IPv4/IPv6 fields; loopbacks included as interfaces.
- Files: pkg/render/interfaces.go
  - Proof: gates/proofs/T031_interfaces.txt (symbols: RenderInterfaces, /interfaces/interface, mtu, ipv4, ipv6, sort)
  - Test: tests/unit/render_interfaces_test.go

T032 [P] Implement qualified BGP global/neighbor and EVPN address-family renderers
- Files: pkg/render/bgp.go
  - Proof: gates/proofs/T032_bgp.txt (symbols: RenderBGP, EVPN, /network-instances/network-instance/protocols/bgp/neighbors)
  - Test: tests/unit/render_bgp_test.go

T033 [P] Implement VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers
- Files: pkg/render/network.go
  - Proof: gates/proofs/T033_vxlan_network.txt (symbols: RenderVXLAN, /interfaces/interface[vtep], bridges, l2vni, RenderNetworkInstances, rd, import-rt, export-rt)

T034 [P] Implement VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, egress End.DT46 renderers
- Files: pkg/render/evpn_advanced.go, pkg/render/srv6.go
  - Proof: gates/proofs/T034_evpn_srv6.txt (symbols: RenderL3VNI, RenderEVPNType5, RenderIRB, RenderSRv6, RenderSRv6Behaviors, RenderSIDList, RenderSRPolicy, H.Encaps.Red, End.DT46, /sonic-srv6:)
  - Test: tests/unit/render_evpn_srv6_test.go

T035 Compose deterministic ordered output, stable names, canonical hashes, compatibility annotations, owner refs, and minimal scoped paths
- Canonical hash and annotations applied to SDC Config; owner references set; minimal paths used under SSA.
- Files:
  - pkg/render/canon.go
    - Proof: gates/proofs/T035_canonical.txt (symbols: CanonicalJSON, CanonicalHash, sort, sha256)
  - controllers/sonicprovider/controller.go (hash annotation and ownerRef)
    - Proof: gates/proofs/T036_T037_apply_validation.txt (symbols: CanonicalHash, annotationHash, SetControllerReference)

T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails
- OfflineValidate and ValidateSpecAgainstRegister called before SSA; on failure, sets condition and requeues without apply.
- File: controllers/sonicprovider/controller.go
  - Proof: gates/proofs/T036_T037_apply_validation.txt (symbols: OfflineValidate, ValidateSpecAgainstRegister)

T037 Implement server-side apply with a dedicated field manager, explicit policy
- File: controllers/sonicprovider/controller.go
  - Proof: gates/proofs/T036_T037_apply_validation.txt (symbols: Patch(ctx, obj, apply, FieldManager), Labels ownerKind)

T038 Observe SDC Config/Target/Deviation status and propagate per-device conditions and Events
- Provider emits DeviationObserved events and sets Degraded/Ready based on SDC status; envtest covers events and status propagation.
- Files:
  - controllers/sonicprovider/controller.go and tests/envtest/provider_events_test.go
    - Proof: gates/proofs/T038_events_status.txt (symbols: DeviationObserved, Ready, Degraded, Eventf, cfg.Status)
  - tests/envtest/provider_sdc_status_propagation_test.go
    - Proof: .wiggum/.../gates/proofs/tests.envtest.provider_sdc_status_propagation.go.proof.txt

T039 Implement bounded backoff/jitter and terminal-vs-transient error classification
- Minimal bounded backoff with jitter implemented via resultWithBackoff(); compat.ValidationError returns stable reasons for terminal conditions.
- Files:
  - controllers/sonicprovider/controller.go
    - Proof: gates/proofs/T039_backoff.txt (symbols: resultWithBackoff, jitter, RequeueAfter)
  - pkg/compat/matrix.go, pkg/compat/compat.go (reason classification)
    - Proof: gates/proofs/T029_compat.txt

T040 Implement ordered finalization: delete owned SDC intent, confirm/timeout, release owned claims, retain recovery evidence
- Provider deletion path deletes owned SDC Config, confirms via get, annotates finalized-at, removes finalizer; envtest simulates flow and asserts durable evidence.
- Files:
  - controllers/sonicprovider/controller.go
    - Proof: gates/proofs/T040_finalization.txt (symbols: finalizer, DeletionTimestamp, Config to be deleted, finalized-at)
  - tests/envtest/provider_finalization_test.go
    - Proof: gates/proofs/T040_finalization.txt (symbols: finalizer, finalized-at)

T041 Instrument reconciles with bounded Prometheus metrics and OTel traces; manifests include probes; in-cluster deployment manifests present (T023)
- Metrics: promauto.NewCounter applies_total; Tracing: otel.Tracer and span around reconcile; Deployment manifest defines readiness/liveness probes.
- Files:
  - controllers/sonicprovider/controller.go, cmd/sonic-provider/main.go, deploy/ainetops/manifests/provider.yaml
    - Proof: gates/proofs/T041_instrumentation_and_manifests.txt (symbols: promauto.NewCounter, applies_total, otel.Tracer, Start(, AddHealthzCheck, AddReadyzCheck, readinessProbe, livenessProbe)

Pinned dependency set (shared by T026/T026a)
- go.mod pins go 1.22, controller-runtime v0.17.5, k8s.io/* v0.29.x, apiextensions-apiserver v0.29.2, zap/logr versions, and otel v1.24.0.
- Proof: gates/proofs/T026_pins_gomod.txt (symbols: go 1.22, controller-runtime v0.17.5, k8s.io/api v0.29.4, client-go v0.29.4, apiextensions-apiserver v0.29.2, otel v1.24.0, zap v1.26.0)

Additional renderer and register tests (deterministic rendering, coverage)
- tests/unit/render_interfaces_test.go, render_bgp_test.go, render_evpn_srv6_test.go, register_guard_test.go ensure determinism and register coverage.
- Proofs: .wiggum/.../gates/proofs/tests.unit.render_interfaces_test.go.proof.txt, tests.unit.render_bgp_test.go.proof.txt, tests.unit.render_register_positive_test.go.proof.txt, tests.unit.register_guard_test.go.proof.txt

Notes
- The provider and SRv6 controllers are scaffolded with the required probes, leader election, SSA, validation, metrics, and traces. The CI guard prevents OpenConfig-vs-SONiC register regressions. Envtest covers CRD validation and provider event/status/finalization behavior. Build/load/deploy inside Kind uses manifests under deploy/ainetops/ and will be exercised in later deployment phases; manifests and probes are present as required.
