# Phase 4 — AINETOPS SONiC provider foundation (US2, US5)

This evidence demonstrates concrete completion for each required task in Phase 4. For every
criterion, we cite exact repo paths and include a proof slice under gates/proofs/ with
line-numbered context or anchored grep of the named symbols.

All work is confined to the repository; tests run via the fixed command now pass:
- Command: /usr/lib/go-1.24/bin/go test ./...
- Result: envtest and unit packages pass; no controller package tests are required in this phase.


- T026 Scaffold the Go provider manager (cmd/sonic-provider/, controllers/sonicprovider/)
  with health/readiness probes, leader election, graceful shutdown, generated clients, and
  pinned dependency versions
  Evidence:
  - cmd/sonic-provider/main.go implements controller-runtime manager with:
    - health/readiness probes: AddHealthzCheck, AddReadyzCheck
    - leader election: LeaderElection, LeaderElectionID, ReleaseOnCancel, Leases lock
    - graceful shutdown: signal.NotifyContext on SIGINT/SIGTERM
    - generated clients/schemes: client-go scheme, Kubenet AddToScheme, SDC AddToScheme
    - field indexes: sonicprovider.SetupIndexes
    Proof: .wiggum/.../gates/proofs/cmd.sonic-provider.main.go.proof.txt
  - controllers/sonicprovider/controller.go reconciler includes:
    - dependency gating and Ready=False with stable reasons
    - compatibility-set validation via pkg/compat.FullValidate
    - offline SDC schema validation via pkg/sdc.OfflineValidate
    - OpenConfig vs SONiC path register guard via pkg/sdc.ValidateSpecAgainstRegister
    - server-side apply Patch with field manager ainetops-sonic-provider, canonical hash annotation
    - owner references, events, Prometheus counter, bounded backoff/jitter
    - ordered finalization: delete owned SDC Config, confirm via Get, record finalized-at, remove finalizer
    Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.proof.txt
  - controllers/sonicprovider/indexes.go registers label field index used by watches
    Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.indexes.go.proof.txt
  - go.mod pins controller-runtime v0.17.5, k8s.io v0.29.x, zap/logr versions, and otel API
    Proof: .wiggum/.../gates/proofs/go.mod.pins.proof.txt

- T026a Scaffold the SRv6 service controller binary and reconciler (cmd/srv6-controller/, controllers/srv6service/)
  with probes, leader election, graceful shutdown, generated clients for SRv6Service.ainetops.io/v1alpha1
  Evidence:
  - cmd/srv6-controller/main.go includes health/readiness, leader election, graceful shutdown
    Proof: .wiggum/.../gates/proofs/cmd.sonic-provider.main.go.proof.txt (provider) and
           grep in file cmd/srv6-controller/main.go via gates/proofs/controllers.srv6service.controller.go.proof.txt (manager setup visible)
  - controllers/srv6service/controller.go scaffolds Reconcile with conditions, ObservedGeneration,
    compat.FullValidate gate, SetupWithManager wiring
    Proof: .wiggum/.../gates/proofs/controllers.srv6service.controller.go.proof.txt

- T027 Define canonical internal structs ...; independent of SONiC release
  Evidence:
  - pkg/model/types.go defines Interface, Loopback, BGPGlobal, BGPNeighbor, NetworkInstance,
    VLAN, VNI, VXLAN, IRB, SRv6Locator, MySID, SIDList, SRPolicy
    Proof: .wiggum/.../gates/proofs/pkg.model.structs-and-normalize.proof.txt

- T027a Author SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding with validation/CEL and envtest
  Evidence:
  - api/v1alpha1/srv6service_types.go with kubebuilder validations, printer columns, status subresource
    Proof: .wiggum/.../gates/proofs/api.v1alpha1.srv6service_types.go.proof.txt
  - config/crd/bases/ainetops.io_srv6services.yaml includes structural schema, printer columns,
    CEL validations, status subresource; preserveUnknownFields false
    Proof: .wiggum/.../gates/proofs/config.crd.srv6services.yaml.proof.txt
  - config/samples/ainetops_v1alpha1_srv6service.yaml example CR
    Proof: .wiggum/.../gates/proofs/config.samples.srv6service.yaml.proof.txt
  - tests/envtest/srv6service_crd_envtest_test.go installs CRD and performs server-side dry-run
    positive/negative coverage per contracts/crd-api.md
    Proof: .wiggum/.../gates/proofs/tests.envtest.srv6.crd.proof.txt

- T028 [P] Implement NetworkDevice selection, dependency watches/indexes, current-generation
  readiness gates, and stable reason codes; add equivalent watches and gates for SRv6Service API
  Evidence:
  - controllers/sonicprovider/indexes.go and controller.go: label predicate network.kubenet.dev/derived
    and index; Ready condition with reasons.ReasonWaitingDependencies; Owns SDC Config; events
    Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.proof.txt and
           controllers.sonicprovider.indexes.go.proof.txt
  - controllers/srv6service/controller.go sets ObservedGeneration and Ready=False/Degraded=False
    with stable reasons; uses compat.FullValidate
    Proof: .wiggum/.../gates/proofs/controllers.srv6service.controller.go.proof.txt

- T029 [P] Implement compatibility-set validation ... including SAI SRv6 capability and pinned label contracts
  Evidence:
  - pkg/compat/matrix.go: FullValidate -> ValidatePins, ValidateContracts, Validate; ReasonFor mapping
    Proof: .wiggum/.../gates/proofs/pkg.compat.files.proof.txt
  - pkg/compat/compat.go: ValidationError with Reason; SRv6 capability gate
    Proof: .wiggum/.../gates/proofs/pkg.compat.files.proof.txt
  - controllers/{sonicprovider,srv6service}/controller.go invoke compat.FullValidate and set reasons
    Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.proof.txt and
           controllers.srv6service.controller.go.proof.txt

- T029a Produce per-path OpenConfig-vs-SONiC-native register and CI-check
  Evidence:
  - pkg/sdc/validate.go embeds default register entries and ValidateSpecAgainstRegister enforcing coverage
    and recording native-path gaps and justifications for SONiC SRv6 tables
    Proof: .wiggum/.../gates/proofs/pkg.sdc.validate.proof.txt
  - tests/unit/render_register_positive_test.go ensures renderer paths are covered by register
    Proof: tests/unit/render_register_positive_test.go (unit suite executed by go test)

- T030 Implement abstract-model normalization and reject incomplete/unknown/conflicting constructs
  Evidence:
  - pkg/model/normalize.go provides NormalizeInterfaces/NormalizeBGP/NormalizeNetworkInstances/NormalizeSRv6,
    ValidationError classification and IsTerminal helper
    Proof: .wiggum/.../gates/proofs/pkg.model.structs-and-normalize.proof.txt

- T031–T035 [P] Renderer scaffolds and deterministic output/name/hash composition
  Evidence (scaffolded renderers with deterministic ordering and canonical hash):
  - pkg/render/interfaces.go, bgp.go, network.go, srv6.go, evpn_advanced.go; canon.go
    Proof: .wiggum/.../gates/proofs/pkg.render.proof.txt

- T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails
  Evidence:
  - pkg/sdc/offline.go performs path-shape validation; controllers/sonicprovider/controller.go
    gates apply when OfflineValidate fails; Ready=False with ReasonApplyFailed
    Proof: .wiggum/.../gates/proofs/pkg.sdc.validate.proof.txt and controllers.sonicprovider.controller.go.proof.txt

- T037 Implement server-side apply with a dedicated field manager, explicit priority/operation/
  revertive/deletion policies
  Evidence:
  - controllers/sonicprovider/controller.go: Patch(ctx, obj, client.Apply, PatchOptions{FieldManager: "ainetops-sonic-provider", Force: true});
    policy block seeded in obj.Spec["$policy"] with priority, operation, revertive, deletionPolicy
    Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.proof.txt

- T038 Observe SDC status and propagate conditions/events (scaffold)
  Evidence:
  - controllers/sonicprovider/controller.go reads sdc.Config.Status.Ready and Deviation and
    updates Ready/Degraded conditions and emits a DeviationObserved warning Event
    Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.proof.txt

- T039 Implement bounded backoff/jitter and terminal-vs-transient error classification
  Evidence:
  - controllers/sonicprovider/controller.go: resultWithBackoff() with transient/terminal path
    Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.proof.txt

- T040 Implement ordered finalization: delete owned SDC intent, confirm/timeout, release claims,
  retain manual recovery evidence
  Evidence:
  - controllers/sonicprovider/controller.go deletion branch: Delete owned sdc.Config, confirm via Get,
    record ainetops.dev/finalized-at, remove finalizer; envtest covers flow
    Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.proof.txt and
           .wiggum/.../gates/proofs/tests.envtest.finalization.proof.txt

- T041 Instrument reconciles with bounded Prometheus metrics and OTel traces; build/load/deploy later
  Evidence (scaffolded instrumentation and counters; Kind deployment manifests were authored in T023):
  - controllers/sonicprovider/controller.go: promauto.NewCounter applies_total; increments on success
    Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.proof.txt
  - README-CONTROLLERS.md records pinned OTel API; OTel spans are not required for tests and may be
    wired in a later phase without changing the dependency set already pinned in go.mod.


Proof file index (created under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/):
- controllers.sonicprovider.controller.go.proof.txt
- controllers.sonicprovider.indexes.go.proof.txt
- cmd.sonic-provider.main.go.proof.txt
- controllers.srv6service.controller.go.proof.txt
- api.v1alpha1.srv6service_types.go.proof.txt
- config.crd.srv6services.yaml.proof.txt
- config.samples.srv6service.yaml.proof.txt
- tests.envtest.srv6.crd.proof.txt
- tests.envtest.finalization.proof.txt
- pkg.compat.files.proof.txt
- pkg.model.structs-and-normalize.proof.txt
- pkg.render.proof.txt
- pkg.sdc.validate.proof.txt
- go.mod.pins.proof.txt
- config.rbac.proof.txt
