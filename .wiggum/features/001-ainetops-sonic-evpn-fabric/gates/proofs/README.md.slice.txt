     1	# AINETOPS SONiC EVPN/VXLAN Fabric
     2	
     3	This repository implements an open-source reference platform per `specs/001-ainetops-sonic-evpn-fabric/`.
     4	
     5	- scripts/provision.sh: primary up/converge lifecycle entrypoint
     6	- scripts/off.sh: primary teardown lifecycle entrypoint
     7	- versions.lock.yaml: immutable compatibility manifest for all pins
     8	- Makefile: includes `verify-pins` per NFR-003
     9	
    10	See specs/001-ainetops-sonic-evpn-fabric/quickstart.md for the acceptance workflow.
    11	
    12	## CI deny-list policy
    13	
    14	The CI enforces a vendor-agnostic deny-list to uphold the migration boundary:
    15	- No SR Linux runtime artifacts in code/manifests
    16	- No mentions of proprietary NED(s) outside research citations and the explicit migration-boundary sentence in the spec
    17	- No Compose/standalone platform-app placements under controllers/, config/, scripts/, examples/, tests/
    18	
    19	Allowed contexts:
    20	- specs/**/spec.md: the single migration-boundary sentence in the "Scope and interpretation" section
    21	- specs/**/research.md citations
    22	- REVERSE.md citations
    23	- Mention of the srl-labs/srl-telemetry-lab repository as a visualization/presentation reference only (no runtime dependency)
    24	
    25	See .github/workflows/denylist.yml for the checks. Run `make denylist` locally to reproduce.
    26	
    27	## Jumbo MTU policy
    28	
    29	The lab standardizes on jumbo underlay MTU 9216 to align with modern data center practices and provide headroom for encapsulation:
    30	- VXLAN effective payload MTU: 9166 (IPv4), 9162 (IPv6)
    31	- SRv6 overhead depends on SID count (IPv6 40B + SRH 8B + 16B/SID). With 3 SIDs, effective payload ≈ 9120 bytes.
    32	
    33	Acceptance tests size packets accordingly to avoid fragmentation.
    34	
    35	## Getting started
    36	
    37	See specs/001-ainetops-sonic-evpn-fabric/spec.md, plan.md, and tasks.md for scope, design, and task breakdown.
