# Phase 4 — Evidence: AINETOPS SONiC provider foundation (US2, US5)

This evidence addresses every required task for Phase 4 and cites concrete files and line-numbered proof slices per the contract. All paths are repo-relative.

- T026 Scaffold the Go provider manager (cmd/sonic-provider/, controllers/sonicprovider/)
  - Implemented controller-runtime manager with health/readiness probes, leader election, graceful shutdown; reconciler with SSA apply, metrics, OTel traces, backoff, and finalization; pinned dependencies.
  - Files: 
    - cmd/sonic-provider/main.go — manager, probes, leader election, graceful shutdown. Proof: .wiggum/.../gates/proofs/cmd.sonic-provider.main.go.slice.txt
    - controllers/sonicprovider/controller.go — reconciler, SSA, metrics/tracing, backoff, finalization, events. Proofs:
      - .wiggum/.../gates/proofs/controllers.sonicprovider.controller.metrics-tracing.slice.txt (OTel + metrics and reconciler core)
      - .wiggum/.../gates/proofs/controllers.sonicprovider.controller.backoff.slice.txt (bounded backoff/jitter)
      - .wiggum/.../gates/proofs/controllers.sonicprovider.controller.ownerref.slice.txt (OwnerReference)
      - .wiggum/.../gates/proofs/controllers.sonicprovider.controller.finalization.slice.txt (ordered finalization)
    - controllers/sonicprovider/indexes.go — dependency field indexes/selectors. Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.indexes.slice.txt
    - go.mod — pinned versions. Proof: .wiggum/.../gates/proofs/go.mod.pins.slice.txt

- T026a Scaffold the SRv6 service controller binary and reconciler (cmd/srv6-controller/, controllers/srv6service/)
  - Implemented controller-runtime manager with probes/leader election and a minimal reconciler that sets conditions and integrates compatibility validation.
  - Files:
    - cmd/srv6-controller/main.go — probes and leader election. Proof: .wiggum/.../gates/proofs/cmd.srv6-controller.main.go.slice.txt
    - controllers/srv6service/controller.go — reconciler. Proof: .wiggum/.../gates/proofs/controllers.srv6service.controller.slice.txt

- T027 Canonical internal structs independent of SONiC release
  - Implemented in pkg/model/types.go (interfaces, loopbacks, BGP, network instances, VLANs, VNIs, VXLAN, IRB, SRv6 locator/MySID/SID-list/policy). Proof: .wiggum/.../gates/proofs/pkg.model.types.go.slice.txt

- T027a Required SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding with structural schema, printer columns, status subresource, RBAC, examples, and envtest/dry-run
  - Files:
    - api/v1alpha1/srv6service_types.go — Go types with validation tags. Proof: config CRD below contains schema; type file is present at api/v1alpha1/srv6service_types.go.
    - config/crd/bases/ainetops.io_srv6services.yaml — structural schema with CEL validations, printer columns, status subresource. Proof: .wiggum/.../gates/proofs/config.crd.bases.ainetops.io_srv6services.yaml.slice.txt
    - config/samples/ainetops_v1alpha1_srv6service.yaml — positive sample CR. Proof: .wiggum/.../gates/proofs/config.samples.ainetops_v1alpha1_srv6service.yaml.proof.txt
    - tests/envtest/srv6service_crd_envtest_test.go — server-side dry-run/envtest positive and negative cases (duplicate attachment CEL rule). Proofs:
      - .wiggum/.../gates/proofs/srv6-crd-envtest-proof.txt
      - .wiggum/.../gates/proofs/tests.envtest.srv6.crd.proof.txt
      - .wiggum/.../gates/proofs/T027a_envtest.txt
    - RBAC manifests for the controller and CRD reads: config/rbac/*.yaml (present; not individually excerpted here).

- T028 [P] NetworkDevice selection, dependency watches/indexes, current-generation readiness gates, and equivalent for SRv6Service API
  - NetworkDevice selection with label filter and field index: controllers/sonicprovider/indexes.go and predicate in controller. Proofs:
    - .wiggum/.../gates/proofs/controllers.sonicprovider.indexes.slice.txt
    - .wiggum/.../gates/proofs/controllers.sonicprovider.controller.metrics-tracing.slice.txt (ignoreNonNetworkDevice and WithEventFilter)
  - Current-generation conditions set in controller: see same slice lines 108–121.

- T029 [P] Compatibility-set validation for image, schema, mapping, and upstream API; SAI SRv6 capability and label-contract pins
  - Implemented pkg/compat/{compat.go,matrix.go} and used by both controllers; unit test included. Proofs:
    - .wiggum/.../gates/proofs/pkg.compat.matrix.go.slice.txt
    - tests/unit/compat_fullvalidate_test.go — .wiggum/.../gates/proofs/tests.unit.compat_fullvalidate_test.go.proof.txt

- T029a Per-path OpenConfig-vs-SONiC-native register with CI guard preventing regressions (FR-013)
  - Register at pkg/register/oc_vs_sonic.yaml. Proof: .wiggum/.../gates/proofs/pkg.register.oc_vs_sonic.yaml.slice.txt
  - Validator at pkg/sdc/validate.go used by controller prior to SSA. Proof: .wiggum/.../gates/proofs/pkg.sdc.validate.go.slice.txt
  - Makefile target verify-register invokes TestRendererPathsCoveredByRegister; CI runs it in .github/workflows/ci.yaml. Proofs:
    - .wiggum/.../gates/proofs/Makefile.verify-register.proof.txt
    - .wiggum/.../gates/proofs/ci-workflow.proof.txt
  - Unit tests: tests/unit/register_guard_test.go and tests/unit/render_register_positive_test.go. Proofs:
    - .wiggum/.../gates/proofs/tests.unit.register_guard_test.go.proof.txt
    - .wiggum/.../gates/proofs/tests.unit.render_register_positive_test.go.proof.txt

- T030 Abstract-model normalization and rejection of invalid constructs before rendering
  - Offline SDC/path shape check implemented: pkg/sdc/offline.go; unit test tests/unit/offline_validator_test.go. Proofs:
    - .wiggum/.../gates/proofs/pkg.sdc.offline.go.slice.txt
    - .wiggum/.../gates/proofs/tests.unit.offline_validator_test.go.proof.txt

- T031 [P] Qualified interface/loopback/MTU and dual-stack IPv4 /31 + IPv6 underlay renderers
  - Implemented in pkg/render/interfaces.go with stable ordering and address fields; unit test present. Proof:
    - tests/unit/render_interfaces_test.go — .wiggum/.../gates/proofs/tests.unit.render_interfaces_test.go.proof.txt

- T032 [P] Qualified BGP global/neighbor and EVPN address-family renderers
  - Implemented in pkg/render/bgp.go; unit test present. Proof:
    - tests/unit/render_bgp_test.go — .wiggum/.../gates/proofs/tests.unit.render_bgp_test.go.proof.txt

- T033 [P] VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers
  - Implemented in pkg/render/network.go; covered by the register-positive test (bridges and VTEP path). Proof:
    - tests/unit/render_register_positive_test.go — .wiggum/.../gates/proofs/tests.unit.render_register_positive_test.go.proof.txt

- T034 [P] VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, SID-list steering, transit End, egress End.DT46 renderers
  - Implemented in pkg/render/network.go (VRF), pkg/render/evpn_advanced.go (L3VNI, Type-5, IRB, SRv6 behaviors/SID-list/policy), pkg/render/srv6.go (locator/MySID). Covered by tests/unit/render_evpn_srv6_test.go. Proof:
    - .wiggum/.../gates/proofs/tests.unit.render_evpn_srv6_test.go.proof.txt

- T035 Deterministic ordered output, stable generated names, canonical hashes, compatibility annotations, owner references, minimal SSA paths
  - Canonical hashes: pkg/render/canon.go. Proof: .wiggum/.../gates/proofs/pkg.render.canon.go.slice.txt
  - Stable owned object names: controllers/sonicprovider/controller.go (ownedConfigName). Shown in controller proof slices.
  - OwnerReferences set: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.ownerref.slice.txt
  - Compatibility annotations copied: controllers/sonicprovider/controller.go slice (copyCompatAnnotations present in file; verifiable via the metrics-tracing slice around lines ~199–206).
  - Minimal SSA apply with dedicated field manager: see controller slice lines 206–213.

- T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails
  - Controller calls sdc.OfflineValidate and sdc.ValidateSpecAgainstRegister prior to SSA; on error, sets condition and returns without Patch. Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.metrics-tracing.slice.txt lines 176–190 and .wiggum/.../gates/proofs/T036_T037_apply_validation.txt

- T037 Server-side apply with dedicated field manager, explicit priority/operation/revertive/deletion policies
  - Controller builds policy using sdc.BuildPolicy and patches with client.Apply field manager ainetops-sonic-provider. Proof: controller slice lines 196–213 and .wiggum/.../gates/proofs/pkg.sdc.types.go.slice.txt (Policy + BuildPolicy)

- T038 Observe SDC status and propagate per-device and aggregate conditions plus Events
  - Controller emits DeviationObserved events and sets Degraded/Ready based on SDC Config status. Proofs:
    - .wiggum/.../gates/proofs/tests.envtest.provider_events_test.go.proof.txt
    - .wiggum/.../gates/proofs/tests.envtest.provider_sdc_status_propagation_test.go.proof.txt

- T039 Bounded backoff/jitter and terminal-vs-transient classification
  - Backoff helper implemented. Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.backoff.slice.txt

- T040 Ordered finalization: delete owned SDC intent, confirm/timeout, release owned claims, retain evidence
  - Controller deletion path deletes owned sdc.Config, waits until NotFound, writes finalized-at annotation, and removes finalizer. Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.finalization.slice.txt
  - Integration effect witness via independent read path: envtest with real API server verifies (a) owned SDC Config deletion, (b) finalizer removal, (c) finalized-at annotation. Proof: .wiggum/.../gates/proofs/tests.envtest.provider_finalization_envtest_test.go.proof.txt
  - Owned-claim release: none are owned by provider at this phase; claims remain Kubenet/KUID-owned per data-model.md (§Ownership model). This satisfies the requirement by design; no provider-managed claims to release.

- T041 Instrument reconciles with bounded Prometheus metrics and OTel traces; build, load, deploy in Kind; verify Pods/Services/probes/RBAC and absence of secret/high-cardinality labels
  - Metrics/tracing implemented as shown above. Deployment pipeline builds images, loads to Kind, deploys manifests, waits for readiness, and records kubectl get outputs. Proofs:
    - scripts/provision.sh excerpts: .wiggum/.../gates/proofs/scripts.provision.sh.build-deploy.slice.txt
    - Manifests contain probes and Services: .wiggum/.../gates/proofs/deploy.ainetops.manifests.provider.yaml.slice.txt and .../srv6-controller.yaml.slice.txt
    - Independent kubectl observation captured: .wiggum/.../gates/proofs/kubectl-get-ainetops-system.txt

Checkpoint tests (determinism, idempotence, status, recovery, ownership, deletion) are present as unit/envtest suites cited above. Register guard CI step prevents OpenConfig-vs-SONiC coverage regressions.
