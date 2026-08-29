# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

REJECTED — specific unmet or unclear criteria and gaps:

- T027a (SRv6Service CRD scaffolding with RBAC and envtest per contracts/crd-api.md):
  - RBAC manifests are not shown. The criterion requires RBAC for the controller; no grounded evidence of config/rbac resources is provided. Provide the actual RBAC YAML that grants the SRv6 controller and provider the least privileges for reads/writes on SRv6Service and any owned resources.
  - NEEDS-GROUNDING:config/rbac/role.yaml

- T034 ([P] Implement VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, and egress End.DT46 renderers):
  - The proof file lists function names, but the actual renderer implementations are not grounded. I cannot verify that H.Encaps.Red, transit End, and End.DT46 are actually rendered, nor that VRF/L3VNI/RD/RT outputs are correct. Show the contents of the renderer files implementing these behaviors and outputs.
  - NEEDS-GROUNDING:pkg/render/evpn_advanced.go
  - NEEDS-GROUNDING:pkg/render/srv6.go
  - NEEDS-GROUNDING:pkg/render/network.go

- T035 (Compose deterministic ordered output, stable generated names, canonical hashes, compatibility annotations, owner references, and minimal scoped paths):
  - Compatibility annotations are not demonstrated anywhere on the generated SDC Config. The controller only sets ainetops.dev/config-hash; there is no grounded code showing annotations for the pinned compatibility set (image/schema/mapping/upstream API versions). Add code to annotate the generated SDC objects with the compatibility pins and provide proof slices.
  - NEEDS-GROUNDING:controllers/sonicprovider/controller.go

- T037 (Implement server-side apply with a dedicated field manager, explicit priority, operation, revertive, and deletion policies):
  - SSA field manager is present, but there is no grounded evidence that an explicit SDC policy block is set (priority, operation, revertive, deletionPolicy). The evidence claims obj.Spec["$policy"] is seeded, but the grounded controller excerpt does not show this. Provide the code that sets the policy block on the SDC Config spec and a proof.
  - NEEDS-GROUNDING:controllers/sonicprovider/controller.go

- T038 (Observe SDC Config/Target/Deviation status and propagate standard per-device and aggregate conditions plus Kubernetes Events):
  - Emitting a DeviationObserved event is shown, but there is no grounded code showing conditions updated from SDC Config/Target/Deviation status (e.g., Ready/Degraded transitions based on SDC). Provide the code that reads SDC status and sets/updates standard conditions accordingly, plus a test proving the condition propagation.
  - NEEDS-GROUNDING:controllers/sonicprovider/controller.go

- T041 (Instrument reconciles with bounded Prometheus metrics and OTel traces; then build, load, and deploy the provider image in Kind; verify Pods/Services/probes/RBAC and absence of secret or high-cardinality metric labels):
  - OTel traces: No grounded OTel import or instrumentation exists. go.mod does not include any go.opentelemetry.io/otel dependency, contradicting the README claim. Add OTel dependencies and instrument reconcile/spans.
  - Build/load/deploy and verification: No grounded evidence of building/loading the provider image, nor deployment manifests/logs/outputs verifying Pods, Services, health/readiness probes, and RBAC behavior in Kind. Provide automated or reproducible evidence (e.g., make target output or test) showing a deployed controller Pod in Kind with probes passing and metrics without secret or high-cardinality labels.

VERDICT 32beb99a4a0ad2d0: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./go`) or state in your evidence that grounding cannot reach it:
- `/usr/lib/go-1.24/bin/go`
- `api.v1alpha1.srv6service_types.go.proof.txt`
- `cmd.sonic-provider.main.go.proof.txt`
- `config.crd.srv6services.yaml.proof.txt`
- `config.rbac.proof.txt`
- `config.samples.srv6service.yaml.proof.txt`
- `controllers.sonicprovider.controller.go.proof.txt`
- `controllers.sonicprovider.indexes.go.proof.txt`
- `controllers.srv6service.controller.go.proof.txt`
- `go.mod.pins.proof.txt`
- `pkg.compat.files.proof.txt`
- `pkg.model.structs-and-normalize.proof.txt`
- `pkg.render.proof.txt`
- `pkg.sdc.validate.proof.txt`
- `tests.envtest.finalization.proof.txt`
- `tests.envtest.srv6.crd.proof.txt`
