# Phase 5 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE5-EVIDENCE.md:

REJECTED criteria and concrete gaps to fix:

- T043 [US3] Add verification for underlay/EVPN sessions, loopback reachability, IPv6 waypoint reachability, and FR-004
  - tests/integration/fabric_verify.sh only echoes placeholders for loopback reachability and IPv6 waypoint reachability and does not perform any actual ping6/traceroute6 checks. Implement real reachability tests and assert success/failure.
  - The “absence of tenant VTEP/VRF state on spines (FR-004)” is only asserted by comment and echo. Add explicit negative checks on spines (e.g., gNMI Get on OpenConfig network-instances/EVPN/VXLAN/NVO/VRF tables) to prove no tenant VTEP/VRF exists on spines.
  - Underlay/EVPN sessions are not validated for state; current code does generic gNMI Get on session-state paths without asserting Established per expected neighbor set, and does not validate EVPN overlay BGP sessions. Add concrete neighbor enumerations and assert session-state=ESTABLISHED for both IPv4 and IPv6, and verify EVPN AF sessions.

- T047 [US3] EVPN client traffic tests
  - tests/integration/evpn_traffic.sh emits only echo lines; no actual traffic or assertions. Implement:
    - Cross-leaf L2 reachability: run containerlab/docker exec pings between client01 and client02 across the L2VNI and fail the test on packet loss.
    - Intra-VRF L3/IRB reachability: generate traffic between endpoints via symmetric-IRB gateway addresses and assert success.
    - Inter-VRF isolation: attempt inter-VRF traffic and assert failure.

- T047a [US3] MTU and ECMP tests
  - MTU: The jumbo ping is implemented and will fail on error due to set -e, which is acceptable.
  - ECMP hashing: Current script sends UDP flows and fetches a single interface’s counters without asserting distribution across equal-cost paths. Add concrete verification that both (or multiple) uplinks see traffic (e.g., read counters on each expected egress interface before/after and assert both increment; or use traceroute variation and per-path counters) and define clear pass/fail criteria.

- T047b [US5] SRv6 capture and counter tests
  - tests/integration/srv6_capture_counters.sh only echoes commands (tcpdump, ip -6 route get, gnmic get) and does not execute or assert anything. Implement:
    - Live tcpdump on the SRv6 source or transit to capture outer IPv6+SRH with ordered SIDs; save pcap or a content hash as proof.
    - Egress decapsulation verification into the intended VRF (e.g., ip -6 route get within the VRF or packet capture on the egress with decapped inner packet).
    - MySID counter increments: read counters before and after traffic and assert an increase.

- T047c [US5] Failover and operator-directed path change
  - tests/integration/srv6_failover_path_change.sh only echoes intended actions; no real failure injection, alert assertion, or path verification is performed.
  - The kubectl patch targets spec.path rather than the required spec.pathPolicy.selectedPath. Fix the field to spec.pathPolicy.selectedPath and implement:
    - Actual primary failure (e.g., containerlab link down) and a check for the corresponding alert/resource condition.
    - Update to alternate path and verify recovery and that the resulting path matches the operator selection without telemetry-driven mutation (e.g., policy table/gNMI state reflects the alternate path; ordered SID list corresponds).

- T048 [US2] Repeat-apply proof (NFR-001)
  - tests/integration/idempotence.sh only echoes requirements and does not observe independent effects. Implement:
    - Capture SDC Config metadata (e.g., annotations like ainetops.dev/config-hash) and SDC/gNMI event streams before/after a no-op apply, and assert zero Config spec writes and zero gNMI Set operations for fabric, tenant, and SRv6 resources.

- T049 [US2] Partial failure/recovery, provider restart mid-transaction, invalid-YANG; partial SRv6 endpoint programming; prohibit false Ready/partial activation
  - tests/integration/failure_recovery_invalid_yang.sh only echoes scenarios. Implement:
    - Partial target failure (e.g., make one leaf unreachable) and verify aggregate status is Degraded (not Ready) with per-target detail; then restore and verify recovery.
    - Provider restart mid-transaction: kill/restart the provider pod during an apply and assert the transaction resumes without duplicate writes and with correct final state.
    - Invalid-YANG: inject an invalid path and prove SDC validation fails and no changed Config is emitted.
    - Partial SRv6 endpoint programming: program only a subset (e.g., one End.DT46) and assert no service activation and no false aggregate Ready.

- T050 [US2] Managed-path drift restoration and unmanaged-path preservation
  - tests/integration/drift_preservation.sh only echoes. Implement:
    - Deliberately drift an SDC-owned path on a device and assert the provider restores intended state (with observable correction via SDC running/intended comparison).
    - Modify an unmanaged device path and prove the provider does not overwrite it.

- T051 [US2] Update/delete lifecycle, ownership, survivability
  - tests/integration/update_delete_survivability.sh only echoes. Implement:
    - Update EVPN and SRv6 services and prove shared fabric state and unrelated claims survive (e.g., via independent reads of Kubenet/SDC resources and device state).
    - Delete SRv6 service and prove SRv6-owned claims and SDC Configs are released while shared IPv6 underlay persists.
    - Provide effect-witness artifacts that record durable identities/content hashes demonstrating pre/post state where applicable.

VERDICT 37a42b1523134406: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./Dockerfile`) or state in your evidence that grounding cannot reach it:
- `cmd/srv6-controller/Dockerfile`
