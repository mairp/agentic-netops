# Phase 1 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE1-EVIDENCE.md:

Unmet or unclear acceptance criteria

- T003 Pinned containerlab version, both SONiC image digests, and redistribution constraints
  - The grounding snapshot of versions.lock.yaml does not show:
    - a containerlab.version (semver),
    - sonic_images.sonic_vs and sonic_images.sonic_vm entries with immutable sha256 digests,
    - notes.redistribution documenting acquisition/redistribution constraints.
  - These are only asserted in the proposer’s proof file, which is not authoritative over the actual on-disk versions.lock.yaml.
  - NEEDS-GROUNDING: versions.lock.yaml

- T004 SONiC/OpenConfig YANG schema commit and compatibility for each SONiC profile
  - The grounding snapshot of versions.lock.yaml does not show:
    - sonic_yang.openconfig_commit (40-hex),
    - sonic_yang.sonic_native_commit (40-hex),
    - a sonic_yang.compatibility list tying each pinned SONiC image (image@sha256) to oc_version/native_version commit prefixes.
  - These details are required to satisfy the “record its compatibility with each SONiC image profile” clause.
  - NEEDS-GROUNDING: versions.lock.yaml

- T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, Grafana Flow plugin, and topology-generation tooling
  - The grounding snapshot of versions.lock.yaml does not show a tooling: section with each image pinned by immutable @sha256 digests (gnmic, otel_collector, prometheus, grafana, grafana_flow_plugin, topology_generator).
  - This is only claimed in the non-authoritative proof file.
  - NEEDS-GROUNDING: versions.lock.yaml

Additional notes to address (do not block the above fixes but should be corrected):
- T008 evidence log appears stale relative to the current pins: validate-crds.run.log shows Kubenet/KUID/SDC refs (e.g., 9f1d2b3…, 1a2b3c4…, v0.31.0) that do not match the current versions.lock.yaml excerpt (kubenet commit bae1c…, kuid commit 7528e…, SDC nested releases). Re-run validate-crds against the current pins or omit the run log from the mapping to avoid confusion. The script itself (server-side dry-run using pinned refs) is present and acceptable.

VERDICT 4f942066de33aee5: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./Makefile.validate-crds.proof.txt`) or state in your evidence that grounding cannot reach it:
- `Makefile.validate-crds.proof.txt`
