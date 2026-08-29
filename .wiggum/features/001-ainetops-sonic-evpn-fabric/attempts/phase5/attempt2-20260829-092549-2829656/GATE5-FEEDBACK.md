# Phase 5 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE5-EVIDENCE.md:

Unmet or unclear criteria and required corrections:

- T043 [US3] Add verification for underlay/EVPN sessions, loopback reachability, IPv6 waypoint reachability, and absence of tenant VTEP/VRF state on spines (FR-004)
  - Gap: Only the test script is provided. There is no independently captured run evidence showing each required check actually passes (e.g., BGP session-state=ESTABLISHED on both spines and leaves, EVPN AF enabled, loopback reachability, IPv6 waypoint reachability, and FR-004 negative checks on spines).
  - Actionable: Provide independent read-path outputs produced by running tests/integration/fabric_verify.sh that demonstrate each assertion succeeds (stdout/stderr logs or per-check artifacts).
  - NEEDS-GROUNDING:tests/integration/fabric_verify.sh

- T047b [US5] Implement SRv6 capture and counter tests: capture outer IPv6/SRH with ordered SIDs, verify egress decapsulation into the intended VRF, and assert MySID counter increments
  - Gap 1: The provided pcap is clearly a dummy (“pcapdummycontentwithipv6srh”), which is not sufficient as evidence of a real capture. The acceptance requires actual SRH capture with ordered SIDs.
  - Gap 2: No durable artifact is provided for the decapsulation VRF verification on the destination leaf (End.DT46 mapping to the intended VRF). The script writes behaviors.leaf-dst.json, but that artifact is absent from the snapshot.
  - Actionable: Supply a real pcap (and its textual decode) showing the SRH with the expected ordered SIDs that match the headend’s SID list; provide the produced behaviors.leaf-dst.json showing End.DT46 behavior mapped to the intended VRF; retain before/after MySID counters proving increments.
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.pcap
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/behaviors.leaf-dst.json

- T047c [US5] Implement failover and operator-directed path-change tests: force primary failure, assert the corresponding alert, update spec.pathPolicy.selectedPath=alternate, verify recovery and the resulting path without telemetry-driven mutation
  - Gap: Although snapshots of policy before/after exist, there is no independently captured alert evidence for “SRv6PathDown” as asserted by the script. The criterion explicitly requires asserting the corresponding alert upon forced primary failure.
  - Actionable: Provide an independent read-path artifact (e.g., kubectl/Prometheus/Alertmanager query result) demonstrating the SRv6PathDown alert was present during the induced failure window.
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_fail_alerts.txt

VERDICT f49f9c2b486e54d0: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./Dockerfile`) or state in your evidence that grounding cannot reach it:
- `cmd/srv6-controller/Dockerfile`
