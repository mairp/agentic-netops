# Gate 4 — Evidence: AINETOPS SONiC provider foundation (US2, US5)

This evidence maps every required task to concrete code and independent line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/. Where a criterion names a file/symbol, we cite that exact path and a proof slice including the symbol text. Files the critic named are grounded explicitly below.

## T026 Scaffold the Go provider manager (`cmd/sonic-provider/`, `controllers/sonicprovider/`) with health/readiness probes, leader election, graceful shutdown, generated clients, and pinned dependency versions

- Provider manager with health/readiness probes, leader election, graceful shutdown, and scheme wiring
  - File: cmd/sonic-provider/main.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.main.probes-leader.slice.txt (shows AddHealthzCheck, AddReadyzCheck, LeaderElection*, signal NotifyContext)
- Reconciler with SSA, conditions, Prometheus metric, OTel tracing, events, backoff, finalization, owner refs, canonical hash
  - File: controllers/sonicprovider/controller.go
  - Proofs:
    - Metrics and tracing: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.metrics-tracing.slice.txt (quotes promauto.NewCounter with no labels and otel.Tracer span)
    - Watches and ownership: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.watches.slice.txt (WithEventFilter(ignoreNonNetworkDevice), Owns(&sdc.Config{}))
- Indexes for dependency selection
  - File: controllers/sonicprovider/indexes.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.indexes.slice.txt (IndexField on metadata.labels.network.kubenet.dev/derived)
- Stable reason codes and pinned deps
  - File: pkg/reasons/reasons.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.reasons.reasons.go.slice.txt
  - File: go.mod pins controller-runtime, k8s.io/*, OTel, Prometheus → cited by earlier phases; unchanged in this phase

## T026a Scaffold the SRv6 service controller binary and reconciler (`cmd/srv6-controller/`, `controllers/srv6service/`) with probes, leader election, graceful shutdown, generated clients for SRv6Service.ainetops.io/v1alpha1

- Manager with probes/leader election and SRv6 API scheme registration
  - File: cmd/srv6-controller/main.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.main.probes-leader.slice.txt
- Reconciler with current-generation conditions and compatibility-set validation
  - File: controllers/srv6service/controller.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.srv6service.controller.go.slice.txt

## T027 Define canonical internal structs … (interfaces, loopbacks, BGP, network instances, VLANs, VNIs, VXLAN, RDs, RTs, IRB, IPv6 underlay, locators, MySIDs, SID lists, behaviors, steering policies)

- File: pkg/model/types.go
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.model.types.go.slice.txt

## T027a Author SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding … with CEL and server-side dry-run/envtest

- API types with validation and XValidation (CEL):
  - File: api/v1alpha1/srv6service_types.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/api.v1alpha1.srv6service_types.go.slice.txt
- Structural schema, printer columns, status subresource, validations:
  - File: config/crd/bases/ainetops.io_srv6services.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.crd.bases.ainetops.io_srv6services.yaml.slice.txt
- Envtest with server-side dry-run positive/negative:
  - File: tests/envtest/srv6service_crd_envtest_test.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.envtest.srv6service_crd_envtest_test.go.slice.txt

## T028 [P] Implement NetworkDevice selection, dependency watches/indexes, current-generation readiness gates …; equivalent for SRv6Service

- Provider predicate and ownership; index wiring: proofs as above under T026 (watches slice and indexes slice)
- Current-generation readiness gates with stable reasons: controllers/sonicprovider/controller.go (Ready=False ReasonWaitingDependencies);
  controllers/srv6service/controller.go (Ready/Degraded init) → proofs above

## T029 [P] Compatibility-set validation … including SAI SRv6 capability and pinned label contracts

- Files: pkg/compat/matrix.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.compat.matrix.go.slice.txt
- Integrated calls in both reconcilers: see controller proof slices

## T029a Produce per-path OpenConfig-vs-SONiC-native register … and CI guard

- Register: pkg/register/oc_vs_sonic.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.register.oc_vs_sonic.yaml.slice.txt
- Guard/validator: pkg/sdc/validate.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.sdc.validate.go.slice.txt

## T030 Implement abstract-model normalization … reject incomplete/unknown/conflicting constructs

- File: pkg/model/normalize.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.model.normalize.go.slice.txt

## T031 [P] Implement qualified interface/loopback/MTU and dual-stack IPv4 /31 plus IPv6 underlay renderers

- File: pkg/render/interfaces.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.render.interfaces.go.slice.txt

## T032 [P] Implement qualified BGP global/neighbor and EVPN address-family renderers

- File: pkg/render/bgp.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.render.bgp.go.slice.txt

## T033 [P] Implement VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers

- File: pkg/render/network.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.render.network.go.slice.txt

## T034 [P] Implement VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, egress End.DT46 renderers

- Files: pkg/render/evpn_advanced.go, pkg/render/srv6.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.render.evpn_advanced.go.slice.txt and pkg.render.srv6.go.slice.txt

## T035 Compose deterministic ordered output, stable generated names, canonical hashes, compatibility annotations, owner references, minimal scoped paths

- Canonical serializer/hash: pkg/render/canon.go (also referenced in controller) → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.render.canon.go.slice.txt
- Provider uses CanonicalHash, annotation key "ainetops.dev/config-hash", SetControllerReference, and minimal SSA paths: covered in controllers.sonicprovider.controller.metrics-tracing.slice.txt lines around CanonicalHash and SSA apply

## T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails

- Files: pkg/sdc/offline.go and pkg/sdc/validate.go used in controller before SSA apply → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.sdc.offline.go.slice.txt and pkg.sdc.validate.go.slice.txt

## T037 Implement server-side apply with a dedicated field manager, explicit priority, operation, revertive, and deletion policies

- SSA PatchOptions.FieldManager set to "ainetops-sonic-provider"; BuildPolicy used under spec["$policy"] prior to SSA → see controller proof slice (SSA section)

## T038 Observe SDC Config/Target/Deviation status and propagate standard per-device and aggregate conditions plus Kubernetes Events

- Early deviation observation and events; aggregate Ready/Degraded condition updates after SDC status read → covered in controllers.sonicprovider.controller.metrics-tracing.slice.txt (pre/post SDC status)

## T039 Implement bounded backoff/jitter and terminal-vs-transient error classification

- resultWithBackoff(transient bool) with jitter cap; classification used for compat (terminal) vs transient apply → in controller; included in proof slice

## T040 Implement ordered finalization: delete owned SDC intent, confirm/timeout, release owned claims, retain manual recovery evidence

- Deletion path deletes owned SDC Config, confirms NotFound, annotates finalized-at, removes finalizer → in controller proof slice

## T041 Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, load, and deploy the provider image inside Kind using T023 manifests; verify Pods, Services, probes, RBAC, and absence of secret/high-cardinality metric labels

- Bounded instrumentation in code:
  - File: controllers/sonicprovider/controller.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.metrics-tracing.slice.txt (Prometheus counter with fixed name ainetops_sonicprovider_applies_total and no user labels; OTel tracer/attributes)
- Build, kind-load, deploy, rollout-wait steps using T023 manifests:
  - File: scripts/provision.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.build-deploy.slice.txt (quotes docker build, kind load, kubectl apply, set image to dev, rollout status, and capture of kubectl get output)
  - Additionally, as requested by the critic, the identical scoped slice is provided at: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/provision-build-deploy.slice.txt
- Deployed manifests with probes/ports:
  - File: deploy/ainetops/manifests/provider.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.manifests.provider.yaml.slice.txt (args include --metrics-bind=:8080 and --health-probe-bind=:8081; readinessProbe/livenessProbe at port 8081; Service exposes 8080)
  - File: deploy/ainetops/manifests/srv6-controller.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.manifests.srv6-controller.yaml.slice.txt (args include --metrics-bind=:8081 and --health-probe-bind=:8082; readinessProbe/livenessProbe at port 8082; Service exposes 8081)
- Independent observation of deployed Pods/Services and readiness:
  - File: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-ainetops-system.txt (line-numbered kubectl get deploy,po,svc -n ainetops-system output)
- RBAC present and scoped; no Secrets or high-cardinality metric labels appear in the controller code or manifests:
  - File: config/rbac/cluster_role.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.cluster_role.yaml.slice.txt

