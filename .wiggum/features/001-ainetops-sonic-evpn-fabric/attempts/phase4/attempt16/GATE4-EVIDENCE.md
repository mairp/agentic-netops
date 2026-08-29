# Gate 4 — Evidence: AINETOPS SONiC provider foundation (US2, US5)

This evidence maps every required task to concrete code and independent line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/. A fixed-argv run of the automated suites now passes after synchronizing the vendor directory and fixing a shell-quoting issue; we do not claim results we did not implement.

- Go static/unit/envtest suites: /usr/lib/go-1.24/bin/go test ./... now succeeds; vendor synced via go mod vendor.

Proofs cited below are workdir-relative. Where a criterion names a file/symbol, we cite that exact path and provide a proof slice that includes the symbol text.

## T026 Scaffold the Go provider manager and reconciler; probes, leader election, graceful shutdown, generated clients, pinned deps

- Manager binary with probes, leader election, graceful shutdown, and scheme wiring:
  - File: cmd/sonic-provider/main.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/provider-main.go.proof.txt
- Provider reconciler with SSA, conditions, OTel/Prometheus instrumentation, events, and backoff:
  - File: controllers/sonicprovider/controller.go
  - Proofs:
    - Header/setup and imports (controller-runtime, prometheus, OTel): .wiggum/.../proofs/provider-controller-header.slice.txt
    - OTel tracer/attributes: .wiggum/.../proofs/provider-controller-otel.slice.txt (quotes "otel.Tracer" and span usage)
    - SSA apply with dedicated field manager and policy: .wiggum/.../proofs/provider-controller-ssa.slice.txt
    - Controller setup (Owns, event filter): .wiggum/.../proofs/provider-controller-setup.slice.txt
    - Finalization flow (ordered delete → confirm → remove finalizer): .wiggum/.../proofs/provider-controller-finalize.slice.txt
    - SDC pre-observation and events: .wiggum/.../proofs/provider-controller-sdc-pre.slice.txt
    - SDC post-observation and conditions: .wiggum/.../proofs/provider-controller-sdc-post.slice.txt
    - Bounded backoff with jitter: .wiggum/.../proofs/provider-controller-backoff.slice.txt
    - Propagating compatibility annotations (keys listed): .wiggum/.../proofs/provider-controller-compat-annotations.slice.txt
- Dependency label selection and field indexes for NetworkDevice:
  - File: controllers/sonicprovider/indexes.go
  - Proof: .wiggum/.../proofs/provider-indexes.proof.txt
- Stable reason codes:
  - File: pkg/reasons/reasons.go
  - Proof: .wiggum/.../proofs/reasons.go.proof.txt
- Pinned dependency versions (Kubernetes/controller-runtime/OTel/Prometheus):
  - File: go.mod
  - Proof: .wiggum/.../proofs/go.mod.pins.slice.txt

## T026a Scaffold the SRv6 service controller binary and reconciler; probes, leader election, graceful shutdown, generated clients for SRv6Service

- Manager binary with probes, leader election, graceful shutdown, and scheme wiring for ainetops.io/v1alpha1:
  - File: cmd/srv6-controller/main.go
  - Proof: .wiggum/.../proofs/srv6-main.go.proof.txt
- SRv6Service reconciler with current-generation conditions and compatibility-set validation gates:
  - File: controllers/srv6service/controller.go
  - Proof: .wiggum/.../proofs/srv6-controller.go.proof.txt

## T027 Canonical internal structs independent of a SONiC release

- Canonical model types: interfaces, loopbacks, BGP (global/neighbor), network instances, VLANs/VNIs/VXLAN, IRB, SRv6 (locator, MySID, SID lists, SR policy):
  - File: pkg/model/types.go
  - Proof: .wiggum/.../proofs/model-types.proof.txt

## T027a Required SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding with structural schema, printer columns, status, CEL, RBAC, samples, and envtest dry-run

- API types with validation tags and CEL XValidation rules:
  - File: api/v1alpha1/srv6service_types.go
  - Proof: .wiggum/.../proofs/srv6service_types.go.proof.txt (quotes SRv6Service, XValidation rules, status fields)
- Structural CRD manifest with printer columns and status subresource:
  - File: config/crd/bases/ainetops.io_srv6services.yaml
  - Proof: .wiggum/.../proofs/crd-srv6services.yaml.proof.txt
- CRD directory notes and sample CR:
  - File: config/crd/README.md → .wiggum/.../proofs/crd-readme.proof.txt
  - File: config/samples/ainetops_v1alpha1_srv6service.yaml → .wiggum/.../proofs/sample-srv6service.yaml.proof.txt
- RBAC for the controller (ClusterRoles for provider and SRv6 controller):
  - File: config/rbac/cluster_role.yaml → .wiggum/.../proofs/rbac-cluster-role.yaml.proof.txt
- Envtest coverage with server-side dry-run of positive/negative cases per the contract:
  - File: tests/envtest/srv6service_crd_envtest_test.go
  - Proof (envtest/dry-run slices): .wiggum/.../proofs/test-srv6-crd-envtest.slice.txt

## T028 [P] NetworkDevice selection, dependency watches/indexes, current-generation readiness gates, and stable reasons; equivalent gates for SRv6Service

- NetworkDevice label selection predicate and ownership of SDC Config, plus index on label:
  - Files: controllers/sonicprovider/controller.go, controllers/sonicprovider/indexes.go
  - Proofs: .wiggum/.../proofs/provider-controller-setup.slice.txt, .wiggum/.../proofs/provider-indexes.proof.txt
- Current-generation condition gates and stable reasons emitted:
  - File: controllers/sonicprovider/controller.go (initial Ready=False, WaitingDependencies)
  - Proof: .wiggum/.../proofs/provider-controller-header.slice.txt (conditions code near lines 108–121)
  - Reasons catalog: pkg/reasons/reasons.go → .wiggum/.../proofs/reasons.go.proof.txt
- Equivalent SRv6Service gating and status handling:
  - File: controllers/srv6service/controller.go
  - Proof: .wiggum/.../proofs/srv6-controller.go.proof.txt (Ready/Degraded initialization, ObservedGeneration)

## T029 [P] Compatibility-set validation for image, schema, mapping, and upstream API versions; SAI SRv6 capability; pinned label contracts

- Compatibility model and validators:
  - Files: pkg/compat/compat.go, pkg/compat/matrix.go
  - Proofs: .wiggum/.../proofs/compat.go.proof.txt, .wiggum/.../proofs/compat-matrix.go.proof.txt (quotes Set, ValidatePins, ValidateContracts, FullValidate)
- Integrated in both reconcilers (SRv6 capability gate and stable Reason mapping):
  - Files: controllers/sonicprovider/controller.go, controllers/srv6service/controller.go
  - Proofs: .wiggum/.../proofs/provider-controller-header.slice.txt (calls compat.FullValidate), .wiggum/.../proofs/srv6-controller.go.proof.txt

## T029a Per-path OpenConfig-vs-SONiC-native register; prefer OpenConfig; record native gaps with justification; CI guard to prevent regressions (FR-013)

- Register file with justifications for SONiC-native SRv6 gaps:
  - File: pkg/register/oc_vs_sonic.yaml → .wiggum/.../proofs/register-oc-vs-sonic.yaml.proof.txt
- Lightweight register validator and embedded default for CI:
  - File: pkg/sdc/validate.go → .wiggum/.../proofs/sdc-offline.go.proof.txt (companion OfflineValidate) and .wiggum/.../proofs/test-register-guard.proof.txt for tests
- Unit tests: negative missing path and positive coverage of all rendered paths:
  - Files: tests/unit/register_guard_test.go, tests/unit/render_register_positive_test.go
  - Proofs: .wiggum/.../proofs/test-register-guard.proof.txt; Makefile target below
- CI workflow and Makefile guard ensure the register stays in sync:
  - Files: .github/workflows/ci.yaml, Makefile
  - Proofs: .wiggum/.../proofs/ci-workflow.proof.txt (Register guard step), .wiggum/.../proofs/makefile-verify-register.slice.txt

## T030 Abstract-model normalization and rejection of incomplete/unknown/conflicting constructs before rendering

- Normalizers and classified terminal errors with IsTerminal helper:
  - File: pkg/model/normalize.go
  - Proof: .wiggum/.../proofs/model-normalize.proof.txt

## T031 [P] Qualified interface/loopback/MTU and dual-stack IPv4 /31 plus IPv6 underlay renderers

- Renderer implements OpenConfig /interfaces/interface with loopbacks and optional MTU/IPv4/IPv6 fields; test asserts stable order:
  - File: pkg/render/interfaces.go → .wiggum/.../proofs/render-interfaces.go.proof.txt
  - File: tests/unit/render_interfaces_test.go → included by register coverage test (also asserts ordering)

## T032 [P] Qualified BGP global/neighbor and EVPN address-family renderers

- Renderer produces OpenConfig BGP global and neighbor entries with l2vpn-evpn AFI/SAFI when requested:
  - File: pkg/render/bgp.go → .wiggum/.../proofs/render-bgp.go.proof.txt
  - File: tests/unit/render_bgp_test.go → exercised in unit tests

## T033 [P] VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers

- VXLAN VTEP source-interface/UDP port, bridges with VLAN/L2VNI:
  - File: pkg/render/network.go → .wiggum/.../proofs/render-network.go.proof.txt
  - Covered by register-positive test: tests/unit/render_register_positive_test.go

## T034 [P] VRF, L3VNI, RD/RT, Type-5, symmetric-IRB; SRv6 locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, egress End.DT46

- EVPN advanced and SRv6 renderers:
  - Files: pkg/render/evpn_advanced.go, pkg/render/srv6.go
  - Proofs: .wiggum/.../proofs/render-evpn_advanced.go.proof.txt, .wiggum/.../proofs/render-srv6.go.proof.txt
  - Unit test exercising combined renderers and register validation:
    - File: tests/unit/render_evpn_srv6_test.go → included in unit suite

## T035 Deterministic output ordering, stable generated names, canonical hashes, compatibility annotations, owner references, minimal SSA paths (FR-007, FR-009)

- Canonical JSON serializer and hash across nested maps/lists:
  - File: pkg/render/canon.go → .wiggum/.../proofs/render-canon.go.proof.txt
- Provider composes owner reference, config-name prefix, canonical hash annotation, and compatibility annotations before SSA:
  - File: controllers/sonicprovider/controller.go
  - Proof: .wiggum/.../proofs/provider-controller-canon-apply.slice.txt (quotes CanonicalHash, annotation key, SetControllerReference)

## T036 Offline SDC/schema validation; emit no changed Config when validation fails

- Offline path-shape validator and register-enforcement prior to any SSA apply:
  - Files: pkg/sdc/offline.go, pkg/sdc/validate.go
  - Proofs: .wiggum/.../proofs/sdc-offline.go.proof.txt; tests/unit/offline_validator_test.go → .wiggum/.../proofs/test-offline-validator.proof.txt
  - Called in provider before SSA: see .wiggum/.../proofs/provider-controller-ssa.slice.txt preface in controller

## T037 Server-side apply (SSA) with a dedicated field manager, explicit priority/operation/revertive/deletion policies

- Policy builder used under spec["$policy"] and SSA Patch with FieldManager:
  - Files: pkg/sdc/types.go (BuildPolicy), controllers/sonicprovider/controller.go (client.Apply with FieldManager)
  - Proofs: .wiggum/.../proofs/sdc-policy-builder.slice.txt, .wiggum/.../proofs/provider-controller-ssa-apply.slice.txt

## T038 Observe SDC Config/Target/Deviation status and propagate standard per-device and aggregate conditions plus Kubernetes Events (FR-014)

- Early deviation observation emits Events regardless of gating; aggregate Degraded/Ready conditions reflect SDC status:
  - File: controllers/sonicprovider/controller.go
  - Proofs: .wiggum/.../proofs/provider-controller-sdc-pre.slice.txt, .wiggum/.../proofs/provider-controller-sdc-post.slice.txt
- Envtest exercises condition/event propagation:
  - Files: tests/envtest/provider_sdc_status_propagation_test.go, tests/envtest/provider_events_test.go
  - Proofs: .wiggum/.../proofs/test-provider-sdc-status.proof.txt, .wiggum/.../proofs/test-provider-events.proof.txt

## T039 Implement bounded backoff/jitter and terminal-vs-transient error classification

- Bounded backoff with jitter helper; classification used for compatibility (terminal) vs transient apply/sequencing:
  - File: controllers/sonicprovider/controller.go
  - Proof: .wiggum/.../proofs/provider-controller-backoff.slice.txt (quotes resultWithBackoff with transient flag)

## T040 Ordered finalization: delete owned SDC intent, confirm/timeout, release owned claims, retain manual recovery evidence

- Reconcile deletion path deletes owned SDC Config, confirms NotFound, annotates "ainetops.dev/finalized-at", and removes finalizer in order:
  - File: controllers/sonicprovider/controller.go
  - Proof: .wiggum/.../proofs/provider-controller-finalize.slice.txt
- Envtest validates ordered finalization and evidence annotation:
  - File: tests/envtest/provider_finalization_test.go → .wiggum/.../proofs/test-provider-finalization.proof.txt

## T041 Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, load, and deploy the provider image inside Kind using T023 manifests; verify Pods, Services, probes, RBAC, and absence of secret/high-cardinality metric labels

- Instrumentation:
  - OTel tracer/span attributes: controllers/sonicprovider/controller.go → .wiggum/.../proofs/provider-controller-otel.slice.txt
  - Prometheus metric counter (no labels — avoids high-cardinality): controllers/sonicprovider/controller.go → .wiggum/.../proofs/provider-controller-setup.slice.txt (quotes promauto.NewCounter)
- Build, kind-load, deploy, and wait for readiness in provision script (uses manifests from T023):
  - File: scripts/provision.sh
  - Proof: .wiggum/.../proofs/provision-build-deploy.slice.txt (quotes docker build, kind load, kubectl apply, rollout status)
- Deployed resources observed via independent kubectl get (namespaces/labels/ports/probes as per manifests):
  - Files: deploy/ainetops/manifests/provider.yaml, deploy/ainetops/manifests/srv6-controller.yaml
  - Proofs: .wiggum/.../proofs/deploy-provider.yaml.proof.txt, .wiggum/.../proofs/deploy-srv6-controller.yaml.proof.txt
  - Independent observation: .wiggum/.../proofs/kubectl-get-ainetops-system.txt
- RBAC manifests:
  - File: config/rbac/cluster_role.yaml → .wiggum/.../proofs/rbac-cluster-role.yaml.proof.txt

---

Checkpoint: Golden and envtest suites cover deterministic rendering, dependency gating, idempotence, status/event propagation, ownership, and deletion. The Makefile guard verify-register and CI workflow prevent OpenConfig-vs-SONiC register regressions.
