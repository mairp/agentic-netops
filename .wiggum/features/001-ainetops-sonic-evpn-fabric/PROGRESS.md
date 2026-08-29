done:
  - T026 Scaffolded Go provider manager and reconciler with health/readiness probes, leader election, graceful shutdown (cmd/sonic-provider/main.go, controllers/sonicprovider/*); pinned deps in go.mod
  - T026a Scaffolded SRv6 controller manager and reconciler with probes/leader election and generated clients (cmd/srv6-controller/main.go, controllers/srv6service/controller.go); SRv6Service types and CRD added (api/v1alpha1, config/crd)
  - T027 Canonical internal structs defined under pkg/model/types.go
  - T027a Envtest for SRv6Service CRD with server-side dry-run (tests/envtest/srv6service_crd_envtest_test.go); RBAC manifests for SRv6Service/Kubenet/SDC and sample CR added under config/rbac/* and config/samples/ainetops_v1alpha1_srv6service.yaml
  - T028 NetworkDevice selection and label/index watches implemented (controllers/sonicprovider/indexes.go) with current-generation conditions
  - T029 Compatibility-set validation integrated with stable reasons (pkg/compat/*), used by both controllers
  - T029a OpenConfig-vs-SONiC register authored (pkg/register/oc_vs_sonic.yaml) and CI guard wired: Makefile verify-register target and .github/workflows/ci.yaml run it; unit tests cover positive and missing-path cases
  - T034 Renderers added for VRF/RD/RT, L3VNI, EVPN Type-5, IRB, SRv6 global/MySID, behaviors, SID lists, and SR policies (pkg/render/*) with unit tests
  - T035 Deterministic canonical JSON and hash implemented (pkg/render/canon.go) and applied as annotation; ownerRef/compat annotations set; minimal SSA paths used
  - T037 SSA apply with dedicated FieldManager and explicit policy fields (priority, operation, revertive, deletionPolicy) via sdc.BuildPolicy(); unit tests exercise composition
  - T038 Event emission implemented and tested (tests/envtest/provider_events_test.go)

verified:
  - Makefile verify-register and CI workflow proof slices under .wiggum/.../gates/proofs
  - Unit tests for register guard and renderers pass locally; envtest sample present

verified:
  - Makefile verify-register and CI workflow proof slices under .wiggum/.../gates/proofs
  - Unit tests for register guard and renderers pass locally; envtest sample present

fixed:
  - T027a missing CR example: added proof slice for config/samples/ainetops_v1alpha1_srv6service.yaml
  - T029a CI guard visibility: verify-register Makefile target and .github/workflows/ci.yaml steps exist; added explicit unit test path TestRendererPathsCoveredByRegister
  - T040 integration witness: added envtest test TestProviderFinalization_Envtest that uses a real API server to verify SDC Config deletion, finalizer removal, and finalized-at annotation

next:
  - Expand golden/idempotence suites; integrate offline SDC/YANG validation; extend integration to assert metrics endpoint and probe responses
