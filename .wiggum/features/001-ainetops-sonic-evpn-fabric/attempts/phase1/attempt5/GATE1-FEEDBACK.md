# Phase 1 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE1-EVIDENCE.md:

REJECTED criteria and gaps:

- T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run
  - The durable run log shows kubectl applied deploy/kubenet/topology.yaml, but the server-side result line reads “topology.network.kubenet.dev/example (server dry-run)”. The current pinned example at deploy/kubenet/topology.yaml has metadata.name: ainetops-topology, not example. This mismatch indicates the log is stale or from a different manifest, so it is not reliable evidence that the current example was validated. Action: Re-run make validate-crds (or scripts/lib/validate_crds.sh) against the current repo state and provide the fresh run log showing the resource name from the present file.
- T003 Select and record a pinned containerlab version and both SONiC profile image digests; document artifact acquisition and redistribution constraints
  - NEEDS-GROUNDING:versions.lock.yaml — The grounded excerpt only covers lines 6–36 and does not include the containerlab:, sonic_images:, or notes: blocks. The proof slice claims these exist (version 0.79.0, both SONiC image digests, and redistribution notes), but I cannot independently verify in the actual file content from the snapshot. Action: Provide grounded content for these sections in versions.lock.yaml.
- T004 Select the SONiC/OpenConfig YANG schema commit and record its compatibility with each SONiC image profile
  - NEEDS-GROUNDING:versions.lock.yaml — The proof file shows sonic_yang.openconfig_commit, sonic_native_commit, and a compatibility block covering both images, but the grounded excerpt does not include this content. Action: Provide grounded content of the sonic_yang: block and the compatibility entries in versions.lock.yaml.
- T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, the Grafana Flow plugin, and topology-generation tooling images/charts
  - NEEDS-GROUNDING:versions.lock.yaml — The proof file shows a tooling: block with @sha256 digests for all required images, but this section is not in the grounded excerpt. Action: Provide grounded content of the tooling: block in versions.lock.yaml.
- T007 Implement reusable strict-shell preflight … tool versions …
  - NEEDS-GROUNDING:scripts/lib/preflight.sh — The grounded snippet clearly shows kubectl, helm, and containerlab version checks; the evidence claims a kind version check is also enforced. That portion is truncated in the snapshot, so I cannot verify the kind version check exists. Action: Provide the grounded preflight::tool_versions implementation segment that validates kind against the pin in versions.lock.yaml.

VERDICT b4f5455aa13cd29a: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
