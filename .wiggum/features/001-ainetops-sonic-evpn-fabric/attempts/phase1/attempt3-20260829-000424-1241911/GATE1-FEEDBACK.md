# Phase 1 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE1-EVIDENCE.md:

REJECTED criteria and gaps:

- T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document API shape
  - The durable run log contradicts the claim of validating the correct, pinned sources:
    - KUID: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log shows validation from kubenet-dev/kuid and only 1 CRD, not the four CRDs from the correct upstream kuidio/kuid (id.kuid.dev_ipindices, id.kuid.dev_asnindices, id.kuid.dev_vniindices, id.kuid.dev_claims).
    - Kubenet: The same run log uses commit 9f1d2b3c… while versions.lock.yaml pins kubenet.commit to bae1c4878257194b64b8435208663a9e286547ed. This is not the pinned commit.
    - SDC: scripts/lib/validate_crds.sh derives sdc_release by grabbing the first “release:” under the sdc section (currently v0.0.58 from config-server) and then constructs URLs against sdcio/sdc/${sdc_release}. That tag scheme does not match the sdcio/sdc repo (run log shows v0.31.0). As written, the script will not consistently validate the pinned SDC CRDs from the correct repo/tag.
  - Required fixes:
    - Update versions.lock.yaml to include an explicit, pinned sdcio/sdc CRD release (e.g., sdc.core.release: vX.Y.Z) distinct from config-server/schema-server, and update scripts/lib/validate_crds.sh to use that field for SDC_CRDS URLs.
    - Ensure scripts/lib/validate_crds.sh uses kuidio/kuid and validates all four KUID CRDs.
    - Re-run make validate-crds and provide an updated .wiggum/.../validate-crds.run.log showing kubectl apply --dry-run=server against:
      - kubenet-dev/kubenet at the pinned commit (bae1c487…),
      - kuidio/kuid at the pinned commit (7528e815…),
      - sdcio/sdc at the pinned CRD release,
      and include the Kubenet example(s).
    - Note: The “api_shape: NetworkConfig” documentation in versions.lock.yaml satisfies the documentation part; the server-side dry-run evidence must be corrected as above.

VERDICT e6149645c50e6a93: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
