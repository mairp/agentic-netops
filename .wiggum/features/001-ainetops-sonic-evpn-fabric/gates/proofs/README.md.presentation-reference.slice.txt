     1	- No SR Linux runtime artifacts in code/manifests
     2	- No mentions of proprietary NED(s) outside research citations and the explicit migration-boundary sentence in the spec
     3	- No Compose/standalone platform-app placements under controllers/, config/, scripts/, examples/, tests/
     4	
     5	Allowed contexts:
     6	- specs/**/spec.md: the single migration-boundary sentence in the "Scope and interpretation" section
     7	- specs/**/research.md citations
     8	- REVERSE.md citations
     9	- Mention of the telemetry visualization lab reference (FR-032) as a presentation-only pattern (no runtime dependency)
    10	
    11	See .github/workflows/denylist.yml for the checks. Run `make denylist` locally to reproduce.
    12	
    13	## Jumbo MTU policy
    14	
    15	The lab standardizes on jumbo underlay MTU 9216 to align with modern data center practices and provide headroom for encapsulation:
    16	- VXLAN effective payload MTU: 9166 (IPv4), 9162 (IPv6)
