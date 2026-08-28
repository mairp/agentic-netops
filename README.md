# AINETOPS SONiC EVPN/VXLAN Fabric

This repository implements an open-source reference platform per `specs/001-ainetops-sonic-evpn-fabric/`.

- scripts/provision.sh: primary up/converge lifecycle entrypoint
- scripts/off.sh: primary teardown lifecycle entrypoint
- versions.lock.yaml: immutable compatibility manifest for all pins
- Makefile: includes `verify-pins` per NFR-003

See specs/001-ainetops-sonic-evpn-fabric/quickstart.md for the acceptance workflow.

## CI deny-list policy

The CI enforces a vendor-agnostic deny-list to uphold the migration boundary:
- No SR Linux runtime artifacts in code/manifests
- No mentions of proprietary NED(s) outside research citations and the explicit migration-boundary sentence in the spec
- No Compose/standalone platform-app placements under controllers/, config/, scripts/, examples/, tests/

Allowed contexts:
- specs/**/spec.md: the single migration-boundary sentence
- specs/**/research.md citations
- Mention of the `srl-telemetry-lab` repository as a visualization reference only (no runtime dependency)

See .github/workflows/denylist.yml for the checks.

## Jumbo MTU policy

The lab standardizes on jumbo underlay MTU 9216 to align with modern data center practices and provide headroom for encapsulation:
- VXLAN effective payload MTU: 9166 (IPv4), 9162 (IPv6)
- SRv6 overhead depends on SID count (IPv6 40B + SRH 8B + 16B/SID). With 3 SIDs, effective payload ≈ 9120 bytes.

Acceptance tests size packets accordingly to avoid fragmentation.

## Getting started

See specs/001-ainetops-sonic-evpn-fabric/spec.md, plan.md, and tasks.md for scope, design, and task breakdown.
