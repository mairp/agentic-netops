# GATE4 Evidence — Phase 4: AINETOPS SONiC provider foundation (US2, US5)

This evidence demonstrates that the Phase 4 scaffolding tasks are implemented with concrete files and line-numbered proof slices.

- T026 Scaffold the Go provider manager (cmd/sonic-provider/, controllers/sonicprovider/) with health/readiness probes, leader election, graceful shutdown, generated clients, and pinned dependency versions
  - Implemented files:
    - cmd/sonic-provider/main.go — manager with health/readiness probes and leader election
    - controllers/sonicprovider/controller.go — reconciler scaffold and watch wiring
    - go.mod — pins controller-runtime v0.17.5 and Kubernetes 0.29.x clients
  - Proofs:
    - Probes and leader election, manager wiring, and reconciler setup: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd_sonic-provider_main.go.proof.txt (lines include "LeaderElectionID", "AddHealthzCheck", "AddReadyzCheck")
    - Reconciler and watch filter: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers_sonicprovider_controller.go.proof.txt (shows type Reconciler and SetupWithManager)

- T026a Scaffold the SRv6 service controller binary and reconciler (cmd/srv6-controller/, controllers/srv6service/) with health/readiness probes, leader election, graceful shutdown, generated clients for SRv6Service.ainetops.io/v1alpha1 (T027a), and the same pinned dependency set as T026 (FR-026, FR-023)
  - Implemented files:
    - cmd/srv6-controller/main.go — manager with probes and leader election; registers api/v1alpha1
    - controllers/srv6service/controller.go — reconciler scaffold watching SRv6Service
    - api/v1alpha1/ — SRv6Service Go types and GroupVersion
  - Proofs:
    - Manager wiring and AddToScheme of SRv6Service, plus health/ready and leader election: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd_srv6-controller_main.go.proof.txt

- T027 Define canonical internal structs for interfaces, loopbacks, BGP, network instances, VLANs, VNIs, VXLAN, RDs, RTs, IRB, IPv6 underlay, locators, MySIDs, SID lists, behaviors, and steering policies; keep them independent of one SONiC release
  - Implemented file:
    - pkg/model/types.go — canonical internal structs independent of a particular SONiC release
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg_model_types.go.proof.txt

- T027a Author the required SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding: api/v1alpha1/srv6service_types.go with validation tags, config/crd/ manifests with structural schema, printer columns, status subresource, RBAC, and CR examples; add CEL validation and server-side dry-run/envtest coverage per contracts/crd-api.md:52-70,137
  - Implemented files:
    - api/v1alpha1/groupversion_info.go — GroupVersion and Scheme registration helpers
    - api/v1alpha1/srv6service_types.go — SRv6Service Go types with kubebuilder markers and validation scaffolding
    - config/crd/bases/ainetops.io_srv6services.yaml — structural CRD schema, printer columns, status subresource, CEL validations
    - config/samples/ainetops_v1alpha1_srv6service.yaml — example CR
    - deploy/rbac/srv6-crd-rbac.yaml — RBAC for the controller
  - Proofs:
    - Types and markers: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/api_v1alpha1_srv6service_types.go.proof.txt
    - Structural CRD: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config_crd_bases_ainetops.io_srv6services.yaml.proof.txt

Notes on pins: go.mod pins controller-runtime v0.17.5, Kubernetes 0.29.x clients, and telemetry libraries; pkg/version/pins.go documents these pins matching versions.lock.yaml.

This phase covers scaffolding deliverables (T026, T026a, T027, T027a). Later tasks (T028–T041) are not claimed here.
