# Phase 2 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE2-EVIDENCE.md:

REASONS FOR REJECTION — unmet or unclear criteria

- T009 [US3] topology annotations: The spec explicitly requires “annotations.” The grounded lab/topology.clab.yml shows mgmt.labels and defaults.labels but no annotations block anywhere in the file. Action: add explicit annotations (e.g., mgmt.annotations and/or topology.defaults.annotations) with AINETOPS metadata, and re-prove via anchored slices for lab/topology.clab.yml.

- T016 [US3] machine-readable report and gate result evidence: While scripts/lib/qualify.sh writes .wiggum/.../qualify.report.json on execution and exits non-zero on failures, there is no grounded example of the machine-readable report being produced. Action: run make lab-qualify and provide the resulting .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.report.json and corresponding qualify.run.log to prove the report is actually emitted and failures gate downstream.
  - Checkpoint also requires at least one immutable SONiC profile to pass both EVPN and SRv6 capability gates. No grounded passing run is provided. Action: include a passing qualify.report.json (result:"pass") and logs for a pinned immutable profile (e.g., sonic-vs or sonic-vm) showing EVPN and SRv6 suites ran and passed with no skips/mocks.

- Inherited obligations from earlier phases (re-check required) — insufficient grounding to judge
  - T002/T003/T004/T005 (pins/compatibility): The spec requires pinned, mutually compatible versions and images. We need to verify those pins and immutability. NEEDS-GROUNDING:versions.lock.yaml (content showing pinned Kind/node image, containerlab, SONiC images, OpenConfig/SONiC YANG commit, gNMIc, OTel, Prometheus, Grafana, Grafana Flow plugin, etc., with immutable digests/commits).
  - T006 implement verify-pins: The Makefile snippet shows verify-compat depends on verify-pins, but the verify-pins target and implementation are not grounded. NEEDS-GROUNDING:Makefile (the verify-pins target lines) and NEEDS-GROUNDING:scripts/lib/verify_pins.sh (content showing rejection of latest/floating refs/missing digests and failure on mismatch).
  - T007 strict-shell preflight: provision.sh sources scripts/lib/preflight.sh, but its content is not grounded. NEEDS-GROUNDING:scripts/lib/preflight.sh (content proving host resource, Kind/runtime, MTU, overlap, KVM checks as specified).
  - T008 CRD validation: The Makefile calls scripts/lib/validate_crds.sh, but its content is not grounded. NEEDS-GROUNDING:scripts/lib/validate_crds.sh (content showing Kubernetes server-side dry-run of pinned Kubenet/KUID and SDC CRDs/examples).
  
Notes
- For T009, do not rely on comments claiming “annotations/labels” — provide actual annotations keys in the YAML and show them in the anchored proof slice.
- For T016/Checkpoint, assertions that it “will pass once images/schemas are present” are insufficient; provide a real run artifact (qualify.report.json and logs) demonstrating the EVPN and SRv6 suites pass under an immutable, pinned profile with no skips/mocks.

VERDICT 1ba16d83a9b2feec: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `versions.lock.yaml`
