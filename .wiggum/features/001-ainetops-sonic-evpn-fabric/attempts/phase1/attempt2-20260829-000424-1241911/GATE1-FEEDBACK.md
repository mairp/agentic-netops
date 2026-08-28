# Phase 1 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE1-EVIDENCE.md:

Unmet or unclear acceptance criteria:

- T008 Validate Kubenet/KUID/SDC CRDs with server-side dry-run; document API shape
  - Gap: The validation script uses the wrong upstream path for KUID CRDs. In scripts/lib/validate_crds.sh (and corroborated by .wiggum/.../scripts.lib.validate_crds.sh.proof.txt lines 33–35), KUID_CRDS points to:
    - https://raw.githubusercontent.com/kubenet-dev/kuid/${kuid_commit}/config/crd/bases/id.kuid.dev_claims.yaml
    This contradicts the pinned repo in versions.lock.yaml (kuid.repo: https://github.com/kuidio/kuid). As written, the script will not validate the actual KUID CRDs, so the requirement to validate upstream KUID CRDs with Kubernetes server-side dry-run is not met. Action: change the KUID_CRDS URL(s) to use the kuidio/kuid repository (e.g., https://raw.githubusercontent.com/kuidio/kuid/${kuid_commit}/config/crd/bases/id.kuid.dev_claims.yaml) and ensure the set fully covers the required KUID CRDs/examples.

VERDICT c8aa6339b27b1d97: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
