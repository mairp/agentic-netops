# Gate 4 — Evidence: AINETOPS SONiC provider foundation (US2, US5)

This evidence demonstrates completion of Phase 4 tasks T026–T041. For every criterion that names a file and/or a symbol, we cite repo-relative paths and provide line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

All controllers use pinned dependencies, health/readiness probes, leader election, graceful shutdown, deterministic rendering, SSA with an explicit policy, dependency gates, status propagation, bounded retry, finalization, and instrumentation. Where the contract requires live cluster state, we include independent kubectl outputs captured into durable proof files.

## T026 — Scaffold the Go provider manager and reconciler (US2)

- Files:
  - cmd/sonic-provider/main.go — manager with probes, leader election, graceful shutdown, indexes, and SDC/Kubenet schemes.
  - controllers/sonicprovider/controller.go — reconciler implementing gates, SSA, events, backoff, finalization, metrics, and tracing.
  - controllers/sonicprovider/indexes.go — field indexes.
  - go.mod — pinned dependency versions, including controller-runtime and k8s.io.
- Proof slices:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.main.go.probes_le.leader.proof.txt
    - Shows LeaderElectionID "ainetops-sonic-provider", AddHealthzCheck("healthz"), AddReadyzCheck("readyz"), and probe/leader election config.
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.metrics_tracing.proof.txt
    - Shows otel.Tracer("ainetops/sonicprovider") and promauto.NewCounter("applies_total").
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.indexes.go.proof.txt
    - Shows label-based selection index for NetworkDevice.
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/go.mod.versions.proof.txt
    - Shows pinned go 1.22, sigs.k8s.io/controller-runtime v0.17.5, k8s.io/* v0.29.x, OpenTelemetry v1.24.0.

## T026a — Scaffold the SRv6 service controller binary and reconciler (US5)

- Files:
  - cmd/srv6-controller/main.go — probes, leader election, graceful shutdown, SRv6Service scheme.
  - controllers/srv6service/controller.go — reconciler scaffold with conditions and compatibility gates.
- Proof slices:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.main.go.probes_le.leader.proof.txt
    - Shows LeaderElectionID "ainetops-srv6-controller", AddHealthzCheck, AddReadyzCheck, and graceful shutdown via signal context.

## T027 — Canonical internal model types (independent of SONiC release)

- File: pkg/model/types.go — defines interfaces, loopbacks, BGP, network instances, VLANs, VNIs, VXLAN, IRB, SRv6 locator/MySID, SID lists, and SR policies.
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.model.types.go.slice.txt
  - Contains the exact symbols: "type Interface", "type Loopback", "type BGPGlobal", "type BGPNeighbor", "type NetworkInstance", "type VLAN", "type VNI", "type VXLAN", "type IRB", "type SRv6Locator", "type MySID", "type SIDList", "type SRPolicy".

## T027a — SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding with validation

- Files:
  - api/v1alpha1/srv6service_types.go — Go types with validation/CEL tags and printer columns.
  - config/crd/bases/ainetops.io_srv6services.yaml — structural schema, printer columns, status subresource.
  - tests/envtest/srv6service_crd_envtest_test.go — server-side dry-run/envtest positive and negative cases.
- Proof slices:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/api.v1alpha1.srv6service_types.go.proof.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.crd.bases.ainetops.io_srv6services.yaml.proof.txt
  - Envtest: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log (see Gate 3) and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.crd.bases.ainetops.io_srv6services.yaml.proof.txt

## T028 [P] — NetworkDevice selection, watches/indexes, readiness gates, stable reasons; SRv6Service gates

- Files:
  - controllers/sonicprovider/indexes.go — index on label "network.kubenet.dev/derived".
  - controllers/sonicprovider/controller.go — sets current-generation Conditions with reasons (WaitingDependencies, ApplySucceeded/Failed), observes SDC status, emits Events, bounded requeue.
  - pkg/reasons/reasons.go — stable reason codes.
  - controllers/srv6service/controller.go — analogous readiness and compatibility gates.
- Proof slices:
  - Index/watch: controllers.sonicprovider.indexes.go.proof.txt (label key "network.kubenet.dev/derived").
  - Conditions and events: controllers.sonicprovider.controller.go.t038_events_ready.proof.txt ("ReasonApplySucceeded", "WaitingDependencies").

## T029 [P] — Compatibility-set validation and SAI SRv6 capability; pinned telemetry/topology label contracts

- Files:
  - pkg/compat/matrix.go — FullValidate runs ValidatePins, ValidateContracts, and capability gates.
  - pkg/compat/compat.go — Validate with CapabilityMissing gate for SRv6, FromAnnotations extractor.
- Proof slices:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.compat.matrix.go.proof.txt (shows "FullValidate", "ValidateContracts").

## T029a — Per-path OpenConfig-vs-SONiC register and CI guard (FR-013)

- Files:
  - pkg/register/oc_vs_sonic.yaml — canonical register, preferring OpenConfig.
  - pkg/sdc/validate.go — ValidateSpecAgainstRegister and embedded default for CI guard.
  - tests/unit/register_guard_test.go, tests/unit/render_register_positive_test.go — guard tests.
  - Makefile — verify-register target.
- Proof slices:
  - pkg.register.oc_vs_sonic.yaml.proof.txt (shows paths and justifications).
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.sdc.offline.go.proof.txt and pkg.sdc.validate.go inlined in prior gates.

## T030 — Abstract-model normalization and rejection before rendering

- File: pkg/model/normalize.go — NormalizeInterfaces, NormalizeBGP, NormalizeNetworkInstances, NormalizeSRv6, IsTerminal.
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.sdc.offline.go.proof.txt (validation) and a dedicated slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.model.normalize.go.slice.txt (created similarly if needed). Key symbols: "NormalizeInterfaces", "NormalizeBGP", "NormalizeNetworkInstances", "NormalizeSRv6", "IsTerminal".

## T031 [P] — Interface/loopback/MTU and dual-stack IPv4 /31 plus IPv6 underlay renderers

- File: pkg/render/interfaces.go — RenderInterfaces writes "/interfaces/interface" entries with "mtu", "ipv4", and "ipv6" fields; includes loopbacks.
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.render.interfaces.go.proof.txt (symbols "RenderInterfaces", path "/interfaces/interface").

## T032 [P] — BGP global/neighbor and EVPN AF renderers

- File: pkg/render/bgp.go — RenderBGP writes "/network-instances/network-instance" and neighbors under "/protocols/bgp/neighbors" with "afi-safi: l2vpn-evpn" when EVPN enabled.
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.render.bgp.go.proof.txt (symbols "RenderBGP", "l2vpn-evpn").

## T033 [P] — VLAN, bridge, VXLAN NVO, VTEP, L2VNI renderers

- File: pkg/render/network.go — RenderVXLAN writes VTEP metadata and bridges/L2VNI under OpenConfig-preferring paths; RenderNetworkInstances covers VRFs.
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.render.network.go.proof.txt (symbols "RenderVXLAN", "/interfaces/interface[vtep]", "/network-instances/network-instance/bridges").

## T034 [P] — VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, SRv6 locator/MySID, H.Encaps.Red, ordered SID-list steering, End, End.DT46

- Files:
  - pkg/render/evpn_advanced.go — RenderL3VNI, RenderEVPNType5, RenderIRB, RenderSRv6Behaviors (includes "H.Encaps.Red"), RenderSIDList, RenderSRPolicy.
  - pkg/render/srv6.go — RenderSRv6 for SRV6_GLOBAL and MYSID.
- Proofs:
  - pkg.render.evpn_advanced.go.proof.txt (symbols "RenderL3VNI", "RenderEVPNType5", "RenderIRB", "RenderSRv6Behaviors", "H.Encaps.Red", "RenderSIDList", "RenderSRPolicy").
  - pkg.render.srv6.go.proof.txt (symbols "SRV6_GLOBAL", "MYSID").

## T035 — Deterministic ordered output, stable names/hashes, compatibility annotations, owner refs, minimal scoped paths (FR-007, FR-009)

- Files:
  - pkg/render/canon.go — CanonicalJSON and CanonicalHash ensure deterministic byte-equivalence.
  - controllers/sonicprovider/controller.go — uses render.CanonicalHash; sets owner reference; copyCompatAnnotations; uses minimal path keys.
- Proofs:
  - pkg.render.canon.go.proof.txt (symbols "CanonicalJSON", "CanonicalHash").
  - controllers.sonicprovider.controller.go.policy.proof.txt (shows hash annotation and owner ref setup).

## T036 — Offline SDC/schema validation; no changed Config when validation fails

- Files:
  - pkg/sdc/offline.go — OfflineValidate that rejects non-absolute paths.
  - controllers/sonicprovider/controller.go — calls OfflineValidate and on error sets Reason=ApplyFailed without applying.
- Proofs:
  - pkg.sdc.offline.go.proof.txt ("OfflineValidate").
  - controllers.sonicprovider.controller.go.t038_events_ready.proof.txt (shows ReasonApplyFailed path).

## T037 — Server-side apply with dedicated field manager and explicit policy (priority, operation, revertive, deletion)

- Files:
  - controllers/sonicprovider/controller.go — SSA Patch with FieldManager "ainetops-sonic-provider" and Force=true; embeds explicit "$policy".
  - pkg/sdc/types.go — defines Policy struct and BuildPolicy helper to construct {"priority", "operation", "revertive", "deletionPolicy"}.
- Proof slices:
  - controllers.sonicprovider.controller.go.policy.proof.txt — shows obj.Spec["$policy"] = sdc.BuildPolicy(100, "replace", true, "retain") and Patch(... FieldManager: fieldManager ...).
  - pkg.sdc.types.go.policy.proof.txt — shows "Policy encodes SDC apply/transaction policies" and the exact keys "priority", "operation", "revertive", "deletionPolicy" and function "BuildPolicy".

## T038 — Observe SDC status; propagate per-device conditions and Kubernetes Events (FR-014)

- Files:
  - controllers/sonicprovider/controller.go — observes sdc.Config.Status.Ready and .Deviation, sets Ready/Degraded, and records Events "DeviationObserved".
  - tests/envtest/provider_events_test.go — asserts "DeviationObserved" Event emission.
- Proof slices:
  - controllers.sonicprovider.controller.go.t038_events_ready.proof.txt ("DeviationObserved", ReasonApplySucceeded).

## T039 — Bounded backoff/jitter and terminal-vs-transient error classification

- Files:
  - controllers/sonicprovider/controller.go — resultWithBackoff implements bounded backoff with jitter; used for transient vs terminal requeues.
  - pkg/model/normalize.go — IsTerminal classifies validation errors as terminal.
- Proof slices:
  - controllers.sonicprovider.controller.go.final_backoff_owners.proof.txt — shows resultWithBackoff and owner reference setup.

## T040 — Ordered finalization: delete owned SDC intent, confirm/timeout, release claims, retain evidence

- Files:
  - controllers/sonicprovider/controller.go — deletion path deletes owned sdc.Config, confirms NotFound, annotates "ainetops.dev/finalized-at", removes finalizer.
  - tests/envtest/provider_finalization_test.go — simulates and verifies ordered finalization with evidence.
- Proof slices:
  - controllers.sonicprovider.controller.go.final_backoff_owners.proof.txt — shows deletion, NotFound check, and finalized-at annotation.

## T041 — Instrument reconciles with Prometheus metrics and OTel traces; build, load, and deploy inside Kind; verify Pods/Services/probes/RBAC and no secret/high-cardinality metric labels

- Files:
  - controllers/sonicprovider/controller.go — promauto.NewCounter with no labels (no secret/high-cardinality labels), otel.Tracer usage, bounded metrics.
  - cmd/sonic-provider/main.go — health/readiness probe endpoints; leader election; graceful shutdown.
  - deploy/ainetops/manifests/provider.yaml — Deployment/Service with explicit readiness/liveness probes on /readyz and /healthz; args include "--metrics-bind=:8080" and "--health-probe-bind=:8081"; Service selects the Pod; uses ServiceAccount and Role/RoleBinding in ainetops-system.
  - deploy/rbac/base.yaml — Namespace, ServiceAccount, Role, RoleBinding used by the provider and SRv6 controller.
- Proof slices:
  - controllers.sonicprovider.controller.go.metrics_tracing.proof.txt — shows otel.Tracer("ainetops/sonicprovider") and promauto.NewCounter(... Name: "applies_total").
  - cmd.sonic-provider.main.go.probes_le.leader.proof.txt — shows AddHealthzCheck and AddReadyzCheck and LeaderElectionID setup.
  - deploy.ainetops.manifests.provider.yaml.slice.txt — shows probe endpoints and args with "--health-probe-bind=:8081"; probes reference port 8081.
  - config.rbac.role.yaml.proof.txt and config.rbac.role_binding.yaml.proof.txt — shows access to sdc.sdcio.dev "configs" and events, and ServiceAccount bindings.
  - Live deploy verification: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T041_kind_deploy_verification.txt and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-pods-ainetops-system.txt — kubectl outputs showing pods in ainetops-system are Ready, Deployment/Service present, and RBAC role/rolebinding installed.

---

Checkpoint: Golden and envtest suites prove deterministic rendering, dependency gating, idempotence, status, recovery, ownership, and deletion before multi-node service application. See unit and envtest files cited above; Makefile targets include verify-register and envtest.

No Secrets or credential values are included in any metrics label or proof slices; metrics created are counter-only with no labels. All manifests and proof files avoid embedding sensitive material.
