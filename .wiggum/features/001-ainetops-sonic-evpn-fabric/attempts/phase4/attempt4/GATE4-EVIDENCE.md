# Gate 4 — Evidence: AINETOPS SONiC provider foundation (US2, US5)

This evidence satisfies T026–T028 and T027a scaffolding. For each criterion that names a file and/or symbol, we cite the exact path and a line-numbered proof slice under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

## T026 — Scaffold Go provider manager and reconciler with probes, leader election, graceful shutdown, watches/indexes, and pinned deps

What we implemented
- Provider manager with health/readiness probes, leader election (leases), graceful shutdown via signal context, bounded lease timings, and controller wiring:
  - File: cmd/sonic-provider/main.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.main.go.proof.txt (lines 40–66, 80–106)
- Reconciler scaffolding that watches Kubenet NetworkDevice objects, filters derived devices, sets a current-generation Ready=False condition with stable reason WaitingDependencies, and requeues with bounded delay:
  - File: controllers/sonicprovider/controller.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.proof.txt (lines 26–49, 58–70)
- Field index for label-based selection, registered at manager startup:
  - File: controllers/sonicprovider/indexes.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.indexes.go.proof.txt (lines 11–27)
- Generic condition upsert for Kubenet's untyped status map:
  - File: controllers/sonicprovider/conditions.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.conditions.go.proof.txt (entire file)
- Minimal pinned Kubenet type to enable watches without importing full upstream, registered to scheme:
  - File: pkg/kubenet/types.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.kubenet.types.go.proof.txt (lines 14–45, 75–84)
- Pinned dependency versions for Go, k8s, and controller-runtime:
  - File: go.mod
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/go.mod.proof.txt (lines 1–13, 69–73)

## T026a — Scaffold SRv6 controller binary and reconciler; probes, leader election; generated clients for SRv6Service (FR-026, FR-023)

What we implemented
- SRv6 controller manager with probes, leader election, graceful shutdown:
  - File: cmd/srv6-controller/main.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.main.go.proof.txt (lines 36–61, 77–89)
- SRv6Service reconciler that sets ObservedGeneration, Ready=False and Degraded=False with Reason=WaitingDependencies, and requeues:
  - File: controllers/srv6service/controller.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.srv6service.controller.go.proof.txt (lines 23–65)
- Generated clients/types for SRv6Service.ainetops.io/v1alpha1:
  - Files: api/v1alpha1/groupversion_info.go, api/v1alpha1/srv6service_types.go, api/v1alpha1/zz_generated.deepcopy.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/api.v1alpha1.srv6service_types.go.proof.txt (lines 9–15, 40–46, 90–111)

## T027 — Canonical internal structs independent of one SONiC release

What we implemented
- Canonical model types covering interfaces, loopbacks, BGP global/neighbor, network instances (VRF/DEFAULT), VLANs/VNIs, VXLAN NVO, IRB, IPv6 underlay fields, SRv6 locators, MySIDs, SID lists, and steering policies:
  - File: pkg/model/types.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.model.types.go.proof.txt (lines 5–19, 21–35, 37–45, 46–57, 58–68, 70–87, 89–94)
- Abstract-model normalization scaffolding that rejects incomplete/duplicate constructs and classifies terminal errors (prepares for T030 but included here for clarity):
  - File: pkg/model/normalize.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.model.types.go.proof.txt (types referenced) and pkg/model/normalize.go (entire file to be used in later phases)

## T027a — Required SRv6Service CRD and scaffolding; structural schema, printer columns, status subresource, RBAC, and CR examples; CEL and envtest

What we implemented
- API types with validation tags and status subresource:
  - File: api/v1alpha1/srv6service_types.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/api.v1alpha1.srv6service_types.go.proof.txt (lines 9–15, 21–39, 40–46, 90–98)
- Structural CRD manifest with schema, printer columns, status subresource, and CEL XValidations:
  - File: config/crd/bases/ainetops.io_srv6services.yaml
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.crd.bases.ainetops.io_srv6services.yaml.proof.txt (lines 1–8, 14–30, 41–76, 101–112, 142)
- Sample CR example that passes validation:
  - File: config/samples/ainetops_v1alpha1_srv6service.yaml
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.samples.ainetops_v1alpha1_srv6service.yaml.proof.txt (entire file)
- RBAC to allow the controller to watch CRDs and SRv6Service status:
  - File: deploy/rbac/srv6-crd-rbac.yaml
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.base.yaml.proof.txt (RBAC base) and cite deploy/rbac/srv6-crd-rbac.yaml for CRD/CR access
- Envtest suite that installs the CRD and validates server-side dry-run positive and negative cases; test automatically skips when envtest binaries are absent, honoring KUBEBUILDER_ASSETS or default /usr/local/kubebuilder/bin:
  - File: tests/envtest/srv6service_crd_envtest_test.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.envtest.srv6service_crd_envtest_test.go.proof.txt (lines 29–39, 41–49, 65–76, 86–89)

## T028 — [P] NetworkDevice selection, dependency watches/indexes, current-generation readiness gates, and stable reason codes

What we implemented
- Controller watches Kubenet NetworkDevice with label predicate network.kubenet.dev/derived=true and field index metadata.labels.network.kubenet.dev/derived:
  - Files: controllers/sonicprovider/controller.go, controllers/sonicprovider/indexes.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.proof.txt (lines 51–56, 58–70); .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.indexes.go.proof.txt (lines 11–27)
- Current-generation readiness gates using stable reason codes from pkg/reasons:
  - Files: controllers/sonicprovider/controller.go, pkg/reasons/reasons.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.proof.txt (lines 36–44); .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.reasons.reasons.go.proof.txt (entire file)

## Additional scaffolding preparing for later tasks

- Compatibility validation scaffolding and pins-from-annotations helper (to be integrated in T029):
  - Files: pkg/compat/compat.go, pkg/compat/matrix.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.compat.compat.go.proof.txt (entire file), .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.compat.matrix.go.proof.txt (entire file)
- OpenConfig vs SONiC-native path register file (initial entries), to be CI-checked in T029a:
  - File: pkg/register/oc_vs_sonic.yaml
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.register.oc_vs_sonic.yaml.proof.txt (entire file)

## Test/run result required by the critic

- Command executed by the critic: /usr/lib/go-1.24/bin/go test ./...
- Current repo state: this command passes (no build failures; envtest suite skips if binaries are unavailable).

