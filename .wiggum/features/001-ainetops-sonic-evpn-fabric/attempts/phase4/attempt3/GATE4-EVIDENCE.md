# Phase 4 — AINETOPS SONiC provider foundation (US2, US5): Evidence for Gate 4

This evidence covers the Phase 4 tasks completed in this pass. For every criterion, we cite concrete files and provide line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

Completed in this pass

- T027a — Added server-side dry-run/envtest coverage for SRv6Service CRD per contracts/crd-api.md:52-70,137
  - Implementation:
    - config/crd/bases/ainetops.io_srv6services.yaml — structural schema with CEL rules already present (see versions committed earlier).
    - tests/envtest/srv6service_crd_envtest_test.go — starts controller-runtime envtest API server, installs the above CRD, and performs server-side dry-run creates for:
      - a valid sample from config/samples/ainetops_v1alpha1_srv6service.yaml (expected success), and
      - a negative case with duplicate attachments violating CEL uniqueness (expected server-side validation failure).
    - Makefile — test target now runs test-envtest, which executes the envtest suite.
  - Proofs:
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6-crd-envtest-proof.txt (extracts tests/envtest/srv6service_crd_envtest_test.go)
    - CRD file path: config/crd/bases/ainetops.io_srv6services.yaml (named file; critic anchors around named symbols/fields)

- T028 — Implemented NetworkDevice selection, dependency indexes, and initial current-generation readiness gating
  - Implementation:
    - pkg/kubenet/types.go — introduced a minimal Kubenet NetworkDevice type and list plus AddToScheme to allow controller-runtime watches without importing upstream modules.
    - controllers/sonicprovider/controller.go — now watches Kubenet NetworkDevice instead of a placeholder ConfigMap and applies a label predicate selecting only derived devices. Reconciler patches a current-generation Ready=False condition with stable reason WaitingDependencies to status to gate downstream changes.
    - controllers/sonicprovider/indexes.go — registers a field index over metadata.labels.network.kubenet.dev/derived for efficient selection.
    - cmd/sonic-provider/main.go — registers Kubenet scheme and calls SetupIndexes before wiring the reconciler; health/readiness probes and leader election already present.
  - Proofs:
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubenet-types-proof.txt (extracts pkg/kubenet/types.go)
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonicprovider-controller-proof.txt (extracts controllers/sonicprovider/controller.go showing For(&kubenet.NetworkDevice{}), predicate, and Ready condition)
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonicprovider-index-proof.txt (extracts controllers/sonicprovider/indexes.go showing the field index)
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonic-provider-main-proof.txt (extracts cmd/sonic-provider/main.go showing kubenet.AddToScheme and SetupIndexes)

Context retained from earlier passes (already satisfied, not reworked here)

- T026 — Provider manager scaffold with probes, leader election, graceful shutdown, pinned dependencies: cmd/sonic-provider/main.go; go.mod; pkg/version/pins.go.
- T026a — SRv6 controller manager and reconciler scaffold with probes, leader election, generated clients: cmd/srv6-controller/main.go; controllers/srv6service/controller.go; api/v1alpha1/*.
- T027 — Canonical internal model structs captured in pkg/model/types.go.

What remains for later Phase 4 tasks (tracked in PROGRESS.md)

- T029–T041 — Compatibility-set validation integration and reasons, OpenConfig-vs-SONiC register and CI, normalization/renderers, SSA/SDC validation and gating, metrics/tracing, retries/finalizers, and in-cluster deployment verification.

Cited files (workdir-relative)

- tests/envtest/srv6service_crd_envtest_test.go
- config/crd/bases/ainetops.io_srv6services.yaml
- pkg/kubenet/types.go
- controllers/sonicprovider/controller.go
- controllers/sonicprovider/indexes.go
- cmd/sonic-provider/main.go

Proof slices

- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6-crd-envtest-proof.txt
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubenet-types-proof.txt
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonicprovider-controller-proof.txt
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonicprovider-index-proof.txt
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonic-provider-main-proof.txt
