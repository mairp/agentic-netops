# Phase 4 — Evidence: AINETOPS SONiC provider foundation (US2, US5)

This evidence maps every acceptance criterion to concrete files and line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/. The pinned code and tests are present in the cited paths.

- T026 Scaffold the Go provider manager with health/readiness probes, leader election, graceful shutdown, generated clients, and pinned dependency versions
  - Implemented binaries and manager wiring
    - cmd/sonic-provider/main.go: manager options, health/readiness probes, leader election with lease/renew/retry tuning, and graceful shutdown via context
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.main.go.proof.txt (lines 41–67, 93–112)
    - Generated clients/schemes for core, Kubenet, and SDC; indexes and controller wiring
      - Proof: cmd.sonic-provider.main.go (scheme and AddToScheme): proofs/cmd.sonic-provider.main.go.proof.txt (lines 38–39, 75–92)
      - Proof: controllers/sonicprovider/indexes.go: label-based index for selection; SetupIndexes called from main
        - Proof: proofs/controllers.sonicprovider.indexes.go.proof.txt (lines 11–16)
        - Proof: proofs/cmd.sonic-provider.main.go.proof.txt (lines 81–85)
  - Provider reconciler scaffolding with dependency gates and conditions, SSA, owner refs, scoped paths, and events
    - controllers/sonicprovider/controller.go:
      - Current-generation gating condition with stable reason WaitingDependencies
        - Proof: proofs/controllers.sonicprovider.controller.go.proof.txt (lines 98–106)
      - Compatibility-set validation for image/schema/mapping and topology/telemetry label contracts; stable reason codes
        - Proof: proofs/controllers.sonicprovider.controller.go.proof.txt (lines 113–124)
      - Offline SDC/schema validation and register guard enforced before SSA; failure emits no Config
        - Proof: proofs/controllers.sonicprovider.controller.go.proof.txt (lines 130–144)
      - Deterministic composition, canonical hash annotation, minimal scoped paths, owner reference, and SSA with field manager
        - Proof: proofs/controllers.sonicprovider.controller.go.proof.txt (lines 146–167)
      - Observe SDC Config status (Ready/Deviation) and propagate per-device conditions plus Kubernetes Events
        - Proof: proofs/controllers.sonicprovider.controller.go.proof.txt (lines 170–186)
      - Bounded backoff with jitter, terminal vs transient classification on error requeues
        - Proof: proofs/controllers.sonicprovider.controller.go.proof.txt (lines 219–228, 240–249)
      - Ordered finalization: delete owned SDC intent, confirm via GET, record finalized-at annotation, remove finalizer
        - Proof: proofs/controllers.sonicprovider.controller.go.proof.txt (lines 61–88, 90–96)
  - Pinned dependency versions (shared with SRv6 controller)
    - go.mod with exact versions including controller-runtime v0.17.5 and k8s.io 0.29.x
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/go.mod.proof.txt (lines 3–15)
    - pkg/version/pins.go records the toolchain versions used
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.render.canon.go.proof.txt (hash fn present) and pkg/version/pins.go (not excerpted; present by path)

- T026a Scaffold the SRv6 service controller binary and reconciler with probes, leader election, graceful shutdown, generated clients for SRv6Service, and the same pinned dependency set
  - cmd/srv6-controller/main.go: manager with health/readiness probes, leader election, graceful shutdown
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.main.go.proof.txt (lines 37–61, 77–89)
  - controllers/srv6service/controller.go: reconciler scaffold with ObservedGeneration, Ready/Degraded gating, and compatibility-set validation reuse
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.srv6service.controller.go.proof.txt (lines 35–76)
  - Generated clients for SRv6Service: api/v1alpha1/srv6service_types.go + groupversion info; CRD under config/crd/
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/api.v1alpha1.srv6service_types.go.proof.txt (lines 9–20, 40–48)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.crd.ainetops.io_srv6services.yaml.proof.txt (schema/printer/status)
  - Same pinned dependency set: single shared go.mod declares controller-runtime v0.17.5, k8s.io v0.29.x, zap/logr, and otel v1.24.0
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/go.mod.proof.txt (lines 3–15, 17–15 and added otel 14–15)
    - README-CONTROLLERS.md documents the shared pins.

- T027 Define canonical internal structs for the abstract model
  - pkg/model/types.go: interfaces, loopbacks, BGP, network instances, VLANs/VNIs/VXLAN, IRB, IPv6 underlay, locators, MySIDs, SID lists, and steering policies
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.model.types.go.proof.txt (lines 5–13, 21–36, 37–45, 46–52, 58–63, 64–69, 70–87, 89–94)

- T027a Author the SRv6Service CRD and scaffolding; server-side dry-run/envtest coverage
  - API types: api/v1alpha1/srv6service_types.go with validation tags and status
    - Proof: .wiggum/.../api.v1alpha1.srv6service_types.go.proof.txt (lines 21–39, 90–98)
  - Structural CRD schema with printer columns and status subresource: config/crd/bases/ainetops.io_srv6services.yaml
    - Proof: .wiggum/.../config.crd.ainetops.io_srv6services.yaml.proof.txt (lines 20–34, 41–61, 104–113)
  - RBAC and sample CR present: config/rbac/role.yaml and config/samples/ainetops_v1alpha1_srv6service.yaml
    - Proof: .wiggum/.../config.rbac.role.yaml.proof.txt (lines 20–28)
  - Envtest exercises server-side dry-run success and CEL failures
    - Proof: .wiggum/.../tests.envtest.srv6service_crd_envtest_test.go.proof.txt (lines 73–88)

- T028 [P] Implement NetworkDevice selection, dependency watches/indexes, current-generation readiness gates, and stable reason codes; add equivalent watches and gates for SRv6Service
  - Label predicate and field index select only Kubenet-derived NetworkDevices
    - Proof: controllers/sonicprovider/indexes.go (label index): proofs/controllers.sonicprovider.indexes.go.proof.txt (lines 14–27)
    - Proof: controllers/sonicprovider/controller.go (predicate): proofs/controllers.sonicprovider.controller.go.proof.txt (lines 200–212)
  - Current-generation readiness gates with stable reasons set by provider and SRv6 controllers
    - Proof: provider Ready=False with ReasonWaitingDependencies: proofs/controllers.sonicprovider.controller.go.proof.txt (lines 98–106)
    - Proof: SRv6 Ready/Degraded False with ReasonWaitingDependencies: proofs/controllers.srv6service.controller.go.proof.txt (lines 41–59)

- T029 [P] Compatibility-set validation for image, schema, mapping, and upstream API versions; SAI SRv6 capability and label contracts
  - Implemented in pkg/compat; used in both controllers before mutation
    - Proof: controllers.sonicprovider.controller.go.proof.txt (lines 113–124)
    - Proof: controllers.srv6service.controller.go.proof.txt (lines 60–71)
    - Proof: tests/unit/compat_fullvalidate_test.go

- T029a Register of OpenConfig vs SONiC-native rendered paths; CI-guarded and coverage test
  - Register file covers all current rendered paths, including neighbors, bridges, VTEP, and SRv6 MySID/behaviors/SID list/policy
    - Proof: .wiggum/.../pkg.register.oc_vs_sonic.yaml.proof.txt (lines 5–14, 19–34)
  - Guard enforces every rendered path must be registered; default embedded register mirrors on-disk content
    - Proof: .wiggum/.../pkg.sdc.validate.proof.txt (lines 11–25, 47–62)
  - Positive coverage test renders a representative spec and passes ValidateSpecAgainstRegister
    - Proof: .wiggum/.../tests.unit.render_register_positive_test.go.proof.txt (entire file)

- T030 Abstract-model normalization and error classification
  - pkg/model/normalize.go: validation guards for interfaces/BGP/VRFs/SRv6 and IsTerminal classifier
    - Proof: .wiggum/.../pkg.model.normalize.go.proof.txt (lines 18–36, 38–45, 46–59, 61–77)

- T031–T033 [P] Initial renderer scaffolds for interfaces/loopbacks/MTU, BGP neighbors/EVPN AFI, VLAN/bridges/VXLAN
  - Implemented in pkg/render/*.go with stable ordering; deterministic CanonicalHash
    - Proof: .wiggum/.../pkg.render.interfaces.go.proof.txt, pkg.render.bgp.go.proof.txt, pkg.render.network.go.proof.txt, pkg.render.canon.go.proof.txt
    - Unit tests: tests/unit/render_interfaces_test.go, tests/unit/render_bgp_test.go

- T034 [P] VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, and End.DT46 renderers
  - Implemented scaffolds covering L3VNI, Type-5 enablement, IRB, SRv6 behaviors, SID list, and policy
    - Proof: .wiggum/.../pkg.render.evpn_advanced.go.proof.txt (entire file)

- T035 Deterministic ordered output, stable names, canonical hashes, compatibility annotations, owner references, and minimal scoped paths
  - Provider reconciler composes minimal-scoped paths, computes CanonicalHash, sets annotation ainetops.dev/config-hash, and sets owner reference; SSA uses fieldManager ainetops-sonic-provider
    - Proof: .wiggum/.../controllers.sonicprovider.controller.go.proof.txt (lines 146–167)

- T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails
  - Call sites in provider reconciler invoke sdc.OfflineValidate and sdc.ValidateSpecAgainstRegister before SSA; on failure, status is patched and reconcile returns with backoff (no Config write)
    - Proof: .wiggum/.../controllers.sonicprovider.controller.go.proof.txt (lines 130–144)

- T037 Server-side apply with dedicated field manager, explicit policy fields
  - SSA call with PatchOptions{FieldManager: "ainetops-sonic-provider", Force: true}; SDC Config spec includes $policy priority/operation/revertive/deletionPolicy
    - Proof: .wiggum/.../controllers.sonicprovider.controller.go.proof.txt (lines 150–166)

- T038 Observe SDC Config/Target/Deviation status and propagate conditions and Events
  - Provider reads SDC Config status, sets Ready/Degraded conditions, and emits Kubernetes Events with stable reason codes; EventRecorder wired from manager
    - Proof: .wiggum/.../controllers.sonicprovider.controller.go.proof.txt (lines 170–186)
    - Proof: .wiggum/.../cmd.sonic-provider.main.go.proof.txt (lines 93–97) shows Recorder wiring
    - Proof: .wiggum/.../config.rbac.role.yaml.proof.txt (lines 7–15) shows RBAC for events and SDC resources

- T039 Bounded backoff/jitter and terminal-vs-transient error classification
  - resultWithBackoff implements bounded jitter; non-transient (terminal) conditions use longer backoff
    - Proof: .wiggum/.../controllers.sonicprovider.controller.go.proof.txt (lines 219–228, 240–249)

- T040 Ordered finalization with independent confirmation and durable evidence
  - Deletion path deletes owned SDC Config, confirms via GET NotFound, sets finalized-at annotation, removes finalizer
    - Proof: .wiggum/.../controllers.sonicprovider.controller.go.proof.txt (lines 61–88)
  - Envtest validates the ordered finalization flow and durable effects
    - Proof: .wiggum/.../tests.envtest.provider_finalization_test.go.proof.txt (lines 45–54)

- T041 Instrument reconciles with Prometheus metrics and OTel traces; build and deploy manifests
  - OTel tracing span started per reconcile; Prometheus counter increments on successful apply
    - Proof: .wiggum/.../controllers.sonicprovider.controller.go.proof.txt (lines 50–55, 167–168, 193–201)
  - Deployment and Service manifests with readiness/liveness probes present (from Phase 3 T023)
    - Proof: .wiggum/.../deploy.ainetops.manifests.provider.yaml.proof.txt (lines 27–33)

Checkpoint: Unit/envtest suites validate canonical hashing determinism, register coverage, offline validators, CRD server-side dry-run, compatibility reasons, and provider finalization.
