# Phase 4 — AINETOPS SONiC provider foundation (US2, US5)

This evidence file demonstrates completion of Phase 4 tasks that are in-scope for this pass (T026, T026a, T027, T027a). It cites concrete paths and provides proof slices under gates/proofs/. All cited files exist and compile; `go test ./...` passes (no tests for these packages yet), clearing the critic’s failing command.

- T026 Scaffold the Go provider manager (cmd/sonic-provider/, controllers/sonicprovider/)
  - Implemented manager with health/readiness probes, leader election, and graceful shutdown.
    - Binary: cmd/sonic-provider/main.go (proof: gates/proofs/phase4-sonic-provider-main.txt)
    - Reconciler scaffold: controllers/sonicprovider/controller.go (proof: gates/proofs/phase4-sonicprovider-controller.txt)
    - Stable reasons and indexes scaffolding: controllers/sonicprovider/reasons.go, controllers/sonicprovider/indexes.go, controllers/sonicprovider/manager.go (proofs: phase4-sonicprovider-reasons.txt, phase4-sonicprovider-indexes.txt, phase4-sonicprovider-manager.txt)
  - Dependency pins compiled successfully via go.mod (proof: gates/proofs/phase4-gomod.txt) and pkg/version/pins.go (proof: gates/proofs/phase4-pins.txt).

- T026a Scaffold the SRv6 service controller binary and reconciler (cmd/srv6-controller/, controllers/srv6service/)
  - Implemented manager with probes and leader election: cmd/srv6-controller/main.go (proof: gates/proofs/phase4-srv6-controller-main.txt)
  - Reconciler watching SRv6Service: controllers/srv6service/controller.go (proof: gates/proofs/phase4-srv6service-controller.txt)

- T027 Define canonical internal structs (independent of SONiC release)
  - Implemented in pkg/model/types.go covering interfaces, loopbacks, BGP, network instances, VLANs, VNIs, VXLAN, IRB, IPv6 underlay-related types, locators, MySIDs, SID lists, and steering policies. (proof: gates/proofs/phase4-model-types.txt)

- T027a Author the required SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding
  - API Go types with kubebuilder markers: api/v1alpha1/srv6service_types.go (proof: gates/proofs/phase4-srv6service-types.txt)
  - GroupVersion/SchemeBuilder: api/v1alpha1/groupversion_info.go (proof: gates/proofs/phase4-srv6service-gv.txt)
  - Minimal deepcopy to satisfy runtime.Object: api/v1alpha1/zz_generated.deepcopy.go (proof: gates/proofs/phase4-srv6service-deepcopy.txt)
  - Structural CRD manifest with status subresource, printer columns, and CEL validations: config/crd/bases/ainetops.io_srv6services.yaml (proof: gates/proofs/phase4-srv6service-crd.txt)
  - RBAC for CRD and resource access: deploy/rbac/srv6-crd-rbac.yaml (proof: gates/proofs/phase4-srv6-crd-rbac.txt)
  - Example CR: config/samples/ainetops_v1alpha1_srv6service.yaml (proof: gates/proofs/phase4-srv6service-sample.txt)

Build/test verification
- go.sum generated and repository compiles with pinned versions. Command and result:
  - Command: /usr/lib/go-1.24/bin/go test ./...
  - Result: ok for internal/lockfile and no-test packages; API/controller packages build successfully. This clears the previously failing CMD-7b0518e1174ca872060e.

Paths changed/added in this phase
- go.mod, go.sum
- cmd/sonic-provider/main.go
- controllers/sonicprovider/{controller.go,indexes.go,reasons.go,manager.go}
- cmd/srv6-controller/main.go
- controllers/srv6service/controller.go
- api/v1alpha1/{groupversion_info.go,srv6service_types.go,zz_generated.deepcopy.go}
- config/crd/bases/ainetops.io_srv6services.yaml
- config/samples/ainetops_v1alpha1_srv6service.yaml
- deploy/rbac/srv6-crd-rbac.yaml
- pkg/model/types.go
- pkg/compat/compat.go (compatibility-set scaffolding) (proof: gates/proofs/phase4-compat.txt)

