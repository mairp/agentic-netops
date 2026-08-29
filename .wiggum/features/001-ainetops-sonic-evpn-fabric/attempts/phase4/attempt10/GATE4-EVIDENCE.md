# Phase 4 — AINETOPS SONiC provider foundation (US2, US5)

This evidence addresses the critic’s failure by fixing the actual code and adding tests. The fixed argv that failed is now passing: `/usr/lib/go-1.24/bin/go test ./...` exits 0 locally. Below I map each implemented checkbox to concrete files and line-numbered proof slices under gates/proofs.

- T026 Scaffold the Go provider manager and reconciler with probes, leader election, graceful shutdown, pinned deps
  - Implemented provider manager binary with health/readiness probes, leader election, graceful shutdown, and index registration:
    - cmd/sonic-provider/main.go
      - Health/readiness and leader election: see proof
      - Registers Kubenet and SDC schemes and controller indexes
    - controllers/sonicprovider/controller.go
      - Reconciler with Ready=False gate, SSA apply with dedicated field manager, owner refs, hash annotation, ordered finalization, SDC status aggregation
    - controllers/sonicprovider/indexes.go registers label-based field index
  - Proofs:
    - .wiggum/.../gates/proofs/cmd.sonic-provider.main.go.proof.txt
    - .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.proof.txt

- T026a Scaffold SRv6 controller binary and reconciler; generated client for SRv6Service.ainetops.io/v1alpha1
  - Implemented:
    - api/v1alpha1/srv6service_types.go with structural schema and validation tags
    - config/crd/bases/ainetops.io_srv6services.yaml (printer columns, status subresource, CEL validations)
    - cmd/srv6-controller/main.go with probes, leader election, graceful shutdown
    - controllers/srv6service/controller.go with gating and compatibility validation
  - Proofs:
    - .wiggum/.../gates/proofs/api.v1alpha1.srv6service_types.go.proof.txt
    - .wiggum/.../gates/proofs/cmd.srv6-controller.main.go.proof.txt
    - .wiggum/.../gates/proofs/controllers.srv6service.controller.go.proof.txt

- T027 Canonical internal structs independent of SONiC release
  - Implemented in pkg/model/types.go (interfaces, loopbacks, BGP global/neighbor, network instances, VLAN, VNI, VXLAN, IRB, SRv6 locator/MySID/SID list, steering policy)
  - Proof: quote file in critic snapshot

- T027a CRD scaffolding and envtest coverage per contracts/crd-api.md 52-70,137
  - CRD: config/crd/bases/ainetops.io_srv6services.yaml with structural schema, printer columns, CEL validations, status subresource
  - Examples: config/samples/ainetops_v1alpha1_srv6service.yaml
  - RBAC: config/rbac/role.yaml minimal verbs
  - Envtest: tests/envtest/srv6service_crd_envtest_test.go uses server-side dry-run on positive/negative samples
  - Proofs listed above; test is exercised by go test ./...

- T028 [P] NetworkDevice selection, dependency watches/indexes, current-generation readiness gates; equivalent for SRv6Service
  - Selection via label predicate ignoreNonNetworkDevice and field index in controllers/sonicprovider/indexes.go
  - Readiness gate Reason=WaitingDependencies set with ObservedGeneration in both controllers
  - Proof: controllers.sonicprovider.controller.go.proof.txt spans and controllers/srv6service/controller.go proof

- T029 [P] Compatibility-set validation and stable reasons (includes SAI SRv6 capability and telemetry/topology label contract)
  - pkg/compat/{compat.go,matrix.go} with Set, pin validations, contract validations, ReasonFor mapping
  - controllers use compat.FullValidate and set Reason from compat.ReasonFor
  - Proof: controllers/srv6service/controller.go proof lines 60–70; controllers/sonicprovider/controller.go proof lines 108–135

- T029a OpenConfig-vs-SONiC register; prefer OpenConfig; guard in CI
  - pkg/sdc/validate.go ValidateSpecAgainstRegister with default embedded register; controllers enforce before SSA
  - Proof: controllers.sonicprovider.controller.go proof lines 165–178 show guard; pkg/sdc/validate.go is in snapshot

- T037 Server-side apply with dedicated field manager, policy, owner references, and canonical hash annotation
  - controllers/sonicprovider/controller.go lines 180–201
  - Proof: controllers.sonicprovider.controller.go.proof.txt

- T039 Bounded backoff and transient vs terminal classification
  - controllers/sonicprovider/controller.go resultWithBackoff; uses different base for transient vs terminal
  - Proof: controllers.sonicprovider.controller.go.proof.txt lines 293–302

- T040 Ordered finalization and durable evidence
  - controllers/sonicprovider/controller.go deletion branch; removes SDC Config, waits, annotates finalized-at, removes finalizer
  - Envtest: tests/envtest/provider_finalization_test.go passes
  - Proof: controllers.sonicprovider.controller.go.proof.txt lines 71–99

- T038 observation of SDC status and propagation to per-device conditions and Events
  - controllers/sonicprovider/controller.go reads sdc.Config and sets Degraded or Ready; records Events
  - Envtest: tests/envtest/provider_sdc_status_propagation_test.go passes
  - Proof: controllers.sonicprovider.controller.go.proof.txt lines 137–158 and 206–224

- T041 instrumentation scaffolds (Prometheus counter and OTel tracer); build/run details recorded earlier in T023
  - controllers/sonicprovider/controller.go imports go.opentelemetry.io/otel and increments a Prometheus counter applies_total; tracer used around reconcile
  - Proof: controllers.sonicprovider.controller.go.proof.txt lines 1–35 and 232–238

Test evidence: go test ./... now passes with envtests:
- ok github.com/mairp/ainetops/tests/envtest

