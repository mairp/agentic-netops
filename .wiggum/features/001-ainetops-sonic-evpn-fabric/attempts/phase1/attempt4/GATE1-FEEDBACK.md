# Phase 1 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE1-EVIDENCE.md:

Unmet or unclear acceptance criteria:

- T003 Select and record a pinned containerlab version and both SONiC profile image digests; document artifact acquisition and redistribution constraints
  - The sonic_vm image digest in versions.lock.yaml is a placeholder (sha256:e3b0c442… — the empty hash), not the immutable digest of a real, operator-built image. The criterion requires both SONiC profile images to be pinned to their actual immutable digests. Action: replace the placeholder with the real sha256 of the operator-built sonic_vm image and keep the redistribution note.
  - If the sonic_images block is not actually present in versions.lock.yaml (only shown via proof slice), provide the grounded content. NEEDS-GROUNDING:versions.lock.yaml

- T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document whether the selected release uses NetworkConfig or NetworkDesign
  - The provided durable run log shows every kubectl apply --dry-run=server attempt failed with 404 Not Found for Kubenet CRDs, KUID CRDs, SDC CRDs, and the Kubenet example. The script then suppresses failures and prints “[validate-crds] OK,” which is not a successful validation. This does not meet the requirement to validate CRDs/examples server-side against the pinned refs.
  - Action: fix validate_crds.sh to point at correct upstream paths for the pinned commit/release set, and re-run to produce a log where kubectl apply --dry-run=server succeeds for the Kubenet CRDs corresponding to the documented API shape (NetworkConfig), the KUID CRDs, the SDC CRDs, and at least one Kubenet example. Include that successful run log as durable evidence.
  - Additionally, ensure Makefile target validate-crds exists and runs the script as claimed. Provide grounded Makefile content showing the validate-crds and verify-compat targets. NEEDS-GROUNDING:Makefile

Notes on other tasks (no changes required to pass, but observed):
- T001: scripts/provision.sh, scripts/off.sh, and shared helpers (preflight, verify_pins, validate_crds) exist on disk; config/kind/cluster.yaml exists; this satisfies the repository skeleton requirement.
- T002: versions.lock.yaml pins kind binary/node image, Kubernetes, controller-runtime, Go, Kubenet, KUID, and SDC (release/commit where applicable). No incompatibility is evident from the lock file slices.
- T004: sonic_yang commit pins and a compatibility matrix are recorded; however this mapping currently references the sonic_vm placeholder digest noted in T003 — once T003 is corrected, ensure the compatibility block references the real sonic_vm@sha256:… entry.
- T005: tooling images appear pinned by digest in versions.lock.yaml (per proof slice). Provide grounded confirmation if needed. NEEDS-GROUNDING:versions.lock.yaml
- T006: scripts/lib/verify_pins.sh implements the required checks (rejects floating refs, missing digests, and incompatible YANG/image metadata). The Makefile proof slice shows a verify-pins target, but the actual Makefile content is not grounded here. Provide the Makefile content to confirm the target wiring. NEEDS-GROUNDING:Makefile
- T007: preflight.sh implements host resources, runtime privilege, address overlap, MTU, KVM (when sonic-vm), and host tool version checks, and provision.sh invokes it; this satisfies the preflight implementation/invocation requirement.

Because T003 and T008 are not met as evidenced above, Phase 1 cannot be approved.

VERDICT 833fd8d9acc8b094: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
