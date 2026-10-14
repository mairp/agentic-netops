# Phase 2 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE2-EVIDENCE.md:

Unmet or insufficiently evidenced criteria

- T023 (image pin enforcement): The spec requires that if containerlab cannot resolve a local image by digest, the topology must “keep the tag” and provision.sh must assert the tag’s image ID equals the pinned digest, failing the bring-up otherwise.
  - NEEDS-GROUNDING:lab/topology.sonic-vm.clab.yml — confirm the sonic-vm image is referenced by TAG (not by digest).
  - NEEDS-GROUNDING:scripts/provision.sh — show the control flow after the mismatch check at the pinned digest comparison (around the excerpted lines 96–107). The provided slice only echoes an error; it does not show an exit. You must prove the bring-up actually fails on mismatch.

- T024 (ConfigMap pin provenance): “Done when the ConfigMap fabric-compat-pins names the image the switches run.” You did not provide any proof that the live ConfigMap’s key sonic-image equals the active profile’s lock entry.
  - Provide a recorded proof (e.g., kubectl jsonpath) showing .data["sonic-image"] in fabric-compat-pins and that it matches the lock pin for the active profile.
  - Alternatively, NEEDS-GROUNDING:scripts/provision.sh — a complete snippet of the ConfigMap heredoc showing exactly how sonic-image is set is partially shown, but the acceptance requires live observation of the ConfigMap content; include a gate proof capturing it.

- T599 (documentation of known exception): Only if T022 says “no” (it does), the sonic-vm profile README must include a “Known exceptions” entry describing:
  - what the exception is (tag in topology),
  - why (containerlab cannot resolve local image by digest),
  - the guard (provision-time assertion),
  - the remediation plan (serve from a local registry so the topology can name the digest).
  - NEEDS-GROUNDING:lab/profiles/sonic-vm/README.md — content is omitted; provide the exact section text showing the “Known exceptions” entry with the required elements.

VERDICT dadb03d03978cb02: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./activate`) or state in your evidence that grounding cannot reach it:
- `agents/.venv/bin/activate`
