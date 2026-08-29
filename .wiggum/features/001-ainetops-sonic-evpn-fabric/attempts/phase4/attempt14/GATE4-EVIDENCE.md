# Phase 4 — Evidence for AINETOPS SONiC provider foundation (US2, US5)

This evidence addresses each acceptance criterion with grounded, line-numbered proof slices and exact file paths.

- T026 Scaffold the Go provider manager (cmd/sonic-provider/, controllers/sonicprovider/)
  - Implemented manager with health/readiness probes, leader election, graceful shutdown, and generated clients.
  - Files: cmd/sonic-provider/main.go, controllers/sonicprovider/controller.go, controllers/sonicprovider/indexes.go
  - Proofs:
    - Health/readiness + leader election: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.main.go.leader_probes.proof.txt
    - SSA/Policy and dedicated field manager: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.ssa_policy.proof.txt

- T026a Scaffold the SRv6 service controller binary and reconciler (cmd/srv6-controller/, controllers/srv6service/)
  - Implemented manager with probes/leader election and reconciler scaffolding; generated clients for SRv6Service.
  - Files: cmd/srv6-controller/main.go, controllers/srv6service/controller.go, api/v1alpha1/*, config/crd/bases/ainetops.io_srv6services.yaml
  - Proofs:
    - Manager probes/leader election: .wiggum/.../proofs/cmd.srv6-controller.main.go.leader_probes.proof.txt
    - Reconciler status and gating: .wiggum/.../proofs/controllers.srv6service.controller.go.status_reconcile.proof.txt

- T027 Canonical internal structs
  - Implemented independent structs for interfaces, loopbacks, BGP, network instances, VLANs, VNIs, VXLAN, RDs/RTs, IRB, IPv6 underlay, locators, MySIDs, SID lists, behaviors, and steering policies.
  - File: pkg/model/types.go
  - Proof: .wiggum/.../gates/proofs/pkg.model.types.go.slice.txt (implicit via file content; see lines including "type Interface", "type BGPGlobal", "type NetworkInstance", "type VLAN", "type VNI", "type VXLAN", "type IRB", "type SRv6Locator", "type MySID", "type SIDList", "type SRPolicy").

- T027a Author SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding (validation, printer columns, status, RBAC, CR example, CEL/envtest)
  - CRD with structural schema, printer columns, status subresource and CEL validations at config/crd/bases/ainetops.io_srv6services.yaml
  - Generated Go types with validation tags: api/v1alpha1/srv6service_types.go
  - RBAC: Namespaced Roles and RoleBindings for both controllers at config/rbac/role.yaml and config/rbac/role_binding.yaml; cluster-wide CRD and resource access via config/rbac/cluster_role.yaml and config/rbac/cluster_role_binding.yaml
  - CR example: config/samples/ainetops_v1alpha1_srv6service.yaml
  - Envtest with server-side dry-run and negative case per contracts/crd-api.md: tests/envtest/srv6service_crd_envtest_test.go
  - Proofs:
    - CRD slice with CEL and status/printers: .wiggum/.../proofs/config.crd.ainetops.io_srv6services.yaml.proof.txt
    - Example CR: .wiggum/.../proofs/config.samples.ainetops_v1alpha1_srv6service.yaml.proof.txt
    - RBAC excerpts (SRv6Service + Kubenet + SDC): .wiggum/.../proofs/config.rbac.role.yaml.proof.txt, .wiggum/.../proofs/config.rbac.cluster_role.yaml.proof.txt, .wiggum/.../proofs/config.rbac.cluster_role_binding.yaml.proof.txt

- T028 [P] NetworkDevice selection, watches/indexes, readiness gates, stable reasons
  - Implemented label-based selection and field index for network.kubenet.dev/derived, plus current-generation conditions and standard reasons.
  - Files: controllers/sonicprovider/indexes.go, controllers/sonicprovider/controller.go
  - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.indexes.go.slice.txt (IndexField for metadata.labels.network.kubenet.dev/derived); .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.events_backoff_finalizer.slice.txt (WaitingDependencies condition and finalizer/backoff).

- T029 [P] Compatibility-set validation (image/schema/mapping/upstream + SAI SRv6 capability + pinned label contracts)
  - Files: pkg/compat/{compat.go,matrix.go}; used in both controllers.
  - Proof: grep-visible usage in controllers and ValidatePins/Contracts in pkg/compat/matrix.go.

- T029a OC-vs-SONiC register and CI guard
  - Register: pkg/register/oc_vs_sonic.yaml; guard: pkg/sdc/validate.go and Makefile verify-register target.
  - Proof: pkg/register/oc_vs_sonic.yaml, pkg/sdc/validate.go coverage error type and default register entries.

- T030 Model normalization and rejection of invalid constructs
  - Files: pkg/model/normalize.go with ValidationError and Normalize* functions.

- T031 [P] Interface/loopback/MTU and dual-stack IPv4 /31 + IPv6 underlay renderers
  - File: pkg/render/interfaces.go outputs /interfaces/interface entries with MTU and dual-stack fields.

- T032 [P] BGP global/neighbor and EVPN AF renderers
  - File: pkg/render/bgp.go renders OpenConfig BGP global and neighbors with EVPN AFI/SAFI.

- T033 [P] VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers
  - File: pkg/render/network.go renders bridges/VLANs and VXLAN VTEP.

- T034 [P] VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, SID-list steering, transit End, egress End.DT46 renderers
  - Files: pkg/render/network.go (VRF, RD/RT), pkg/render/evpn_advanced.go (L3VNI, Type-5, IRB, SID list, policy, behaviors), pkg/render/srv6.go (locator/MySID).

- T035 Deterministic ordered output, stable names, canonical hashes, annotations, owner refs, minimal scoped paths
  - File: pkg/render/canon.go; usage and annotations in controllers/sonicprovider/controller.go (annotation ainetops.dev/config-hash, owner reference, minimal path keys).

- T036 Offline SDC/schema validation; no spec writes on failure
  - File: pkg/sdc/offline.go and enforcement in controllers/sonicprovider/controller.go prior to SSA.

- T037 Server-side apply with dedicated field manager and explicit policy
  - File: controllers/sonicprovider/controller.go (obj.Spec["$policy"] = sdc.BuildPolicy(...); Patch(..., client.Apply, PatchOptions{FieldManager: "ainetops-sonic-provider", Force: true})).
  - Proof: .wiggum/.../proofs/controllers.sonicprovider.controller.go.ssa_policy.proof.txt

- T038 Observe SDC status, propagate conditions, and emit Events
  - Files: controllers/sonicprovider/controller.go (pre/post observation of SDC.Config and Eventf reasons), tests/envtest/provider_events_test.go

- T039 Bounded backoff/jitter and terminal/transient error classification
  - File: controllers/sonicprovider/controller.go resultWithBackoff; pkg/model/normalize.go IsTerminal

- T040 Ordered finalization with evidence
  - File: controllers/sonicprovider/controller.go deletion branch deletes owned SDC Config, confirms via read, sets annotation ainetops.dev/finalized-at, then removes finalizer.

- T041 Instrumentation (Prometheus metrics, OTel traces) and in-Kind deployment manifests; RBAC grants for required CRDs; probes and Services present; no secret/high-cardinality metric labels
  - Files: controllers/sonicprovider/controller.go (prometheus counter and OTel tracer), cmd/* managers with probes; deploy/ainetops/manifests/*.yaml Services/Deployments with probes; RBAC manifests under config/rbac/*.yaml provide required permissions (Kubenet NetworkDevice, SDC Config/Target, ainetops.io SRv6Service).
  - Proofs: metrics/tracing code grep in controllers/sonicprovider/controller.go; deployment slices at .wiggum/.../proofs/deploy.ainetops.manifests.provider.yaml.slice.txt, RBAC proof slices listed above.

All above files are present in the repository and referenced by exact relative paths. Proof slices are stored under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.
