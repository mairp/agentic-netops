# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

Unmet or unclear criteria with concrete gaps to address:

- T041 Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, load, and deploy the provider image inside Kind using T023 manifests; verify Pods, Services, probes, RBAC, and absence of secret/high-cardinality metric labels
  - Instrumentation evidence in controllers/sonicprovider/controller.go shows an unlabelled Prometheus counter and OTel tracing, satisfying the bounded metrics/trace portion. RBAC manifests exist at config/rbac/cluster_role.yaml.
  - Missing independently readable deployment verification. The claim that the image is built, kind-loaded, and deployed, and that Pods/Services/probes are correct, is not substantiated by grounded artifacts in the snapshot.
    - NEEDS-GROUNDING:scripts/provision.sh (to verify docker build, kind load, kubectl apply, and rollout status steps and that T023 manifests are used)
    - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/provision-build-deploy.slice.txt (to confirm the commands actually executed)
    - NEEDS-GROUNDING:deploy/ainetops/manifests/provider.yaml (to verify liveness/readiness probes and ports configured for the manager)
    - NEEDS-GROUNDING:deploy/ainetops/manifests/srv6-controller.yaml (to verify probes for SRv6 controller if claimed)
    - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-ainetops-system.txt (to independently observe the deployed Pods/Services and their readiness)

Notes:
- Other tasks (T026, T026a, T027a, T029a, and previously confirmed T027, T028–T040) are supported by grounded code and proofs in this snapshot without contradiction.
- Do not remove the NEEDS-GROUNDING files from the proof set; the content of these specific files is required to judge T041 conclusively.

VERDICT b8cc4b6611988f85: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./go`) or state in your evidence that grounding cannot reach it:
- `/usr/lib/go-1.24/bin/go`
