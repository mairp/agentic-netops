# Phase 4 — Evidence: AINETOPS SONiC provider foundation (US2, US5)

This evidence addresses the critic feedback and demonstrates concrete completion of the scoped Phase 4 tasks we implemented in this pass. Each item cites exact repo paths and includes a proof slice under .wiggum/.../gates/proofs/ that shows the required symbols and logic.

Important: Only the tasks we actually implemented in this pass are claimed below. Remaining tasks (renderers, full offline SDC validation, metrics/tracing, etc.) are explicitly left for subsequent passes per PROGRESS.md.

- T026 Scaffold the Go provider manager with health/readiness probes, leader election, graceful shutdown, generated clients, and pinned dependency versions
  - Files:
    - cmd/sonic-provider/main.go
    - controllers/sonicprovider/{controller.go,indexes.go,conditions.go}
    - go.mod (pinned controller-runtime/k8s versions)
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.main.go.proof.txt — shows Manager options with LeaderElection, health/readiness probes, and index setup
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.proof.txt — shows controller scaffolding
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.indexes.go.proof.txt — shows field index registration

- T026a Scaffold the SRv6 service controller binary and reconciler with health/readiness probes, leader election, graceful shutdown, generated clients for SRv6Service
  - Files:
    - cmd/srv6-controller/main.go
    - controllers/srv6service/controller.go
    - api/v1alpha1/{groupversion_info.go,srv6service_types.go,zz_generated.deepcopy.go}
    - config/crd/bases/ainetops.io_srv6services.yaml (structural schema, printer columns, status)
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.main.go.proof.txt (existing) — shows probes/leader election
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.srv6service.controller.go.proof.txt — shows Reconciler watching SRv6Service

- T027 Define canonical internal structs (interfaces, loopbacks, BGP, network instances, VLANs/VNIs/VXLAN, IRB, IPv6 underlay, locators, MySIDs, SID lists, steering policies)
  - Files: pkg/model/types.go, pkg/model/normalize.go
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/repo-structure.txt (existing, directory context)

- T027a Required SRv6Service CRD and scaffolding with validation and envtest coverage
  - Files: api/v1alpha1/srv6service_types.go, config/crd/bases/ainetops.io_srv6services.yaml, config/samples/ainetops_v1alpha1_srv6service.yaml, tests/envtest/srv6service_crd_envtest_test.go
  - Proofs: existing proof slices for CRD and envtest; and go test ./tests/envtest executes (see logs from CI gate)

- T028 Implement NetworkDevice selection, dependency watches/indexes, current-generation readiness gates, stable reason codes
  - Files: controllers/sonicprovider/{controller.go,indexes.go}, pkg/kubenet/types.go, pkg/reasons/reasons.go
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.proof.txt — shows Ready=False with reason "WaitingDependencies" and patched status; watch filter for Kubenet-derived devices
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.indexes.go.proof.txt — shows the field index

- T029 Implement compatibility-set validation (image, schema, mapping, upstream API); SAI SRv6 capability; pinned telemetry/topology label contracts; wire into reconcilers with stable reasons and gating
  - Files: pkg/compat/{compat.go,matrix.go}; controllers/sonicprovider/controller.go; controllers/srv6service/controller.go
  - What changed: Both reconcilers now call compat.FullValidate(…) using annotations/labels and set condition Reason=SchemaMismatch or Reason=CapabilityMissing; downstream SDC apply is gated until validation passes.
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.compat.matrix.go.reason.proof.txt — shows FullValidate and ReasonFor mapping
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.srv6service.controller.go.proof.txt — shows compat.FullValidate use in SRv6 controller
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.proof.txt — shows compat.FullValidate use in provider reconcile

- T029a Per-path OpenConfig-vs-SONiC-native register and guard
  - Files: pkg/register/oc_vs_sonic.yaml; pkg/sdc/validate.go
  - What changed: Provider reconcile calls sdc.ValidateSpecAgainstRegister before SSA; it rejects any rendered YANG path that lacks a register entry. The default embedded register mirrors pkg/register/oc_vs_sonic.yaml. A fuller CI linter integrating renderer enumeration will follow after renderers land.
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.register.oc_vs_sonic.yaml.proof.txt — shows register entries
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.sdc.validate.go.proof.txt — shows ValidateSpecAgainstRegister

- T037 Server-side apply with a dedicated field manager, explicit policies; owner references, canonical hashes, deterministic composition anchors
  - Files: controllers/sonicprovider/controller.go
  - What changed: SSA via client.Apply with FieldManager "ainetops-sonic-provider" and Force; SDC Config gets ownerRef to NetworkDevice and ainetops.dev/config-hash annotation (sha256 of composed spec). Minimal deterministic anchor path included.
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.proof.txt — shows SSA, field manager, owner ref, and hash annotation logic

- T039 Bounded backoff/jitter and terminal-vs-transient classification hook
  - Files: controllers/sonicprovider/controller.go
  - What changed: resultWithBackoff adds jitter and longer intervals for terminal errors; used for validation failures and apply errors. pkg/model.IsTerminal exists as a hook for later renderers; current integration distinguishes validation/SSA failures.
  - Proofs: controllers.sonicprovider.controller.go.proof.txt slice shows resultWithBackoff

- T040 Ordered finalization
  - Files: controllers/sonicprovider/controller.go
  - What changed: ainetops.dev/finalizer added; on deletion, owned SDC Config is deleted first; finalize evidence is recorded with ainetops.dev/finalized-at annotation; finalizer is then removed.
  - Proofs: controllers.sonicprovider.controller.go.proof.txt slice shows finalizer name and deletion flow

Build/tests sanity: go test ./... completes for envtest suite and builds all packages in this pass. See CI run or local run logs.

Not in scope in this pass (tracked in PROGRESS.md): T031–T036, T038, T041 (renderers, full SDC validation, status aggregation/events, metrics/tracing and Kind deployment verification).
