# Phase 5 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE5-EVIDENCE.md:

REJECTED: Specific unmet or insufficiently evidenced criteria

- T047b [US5] Implement SRv6 capture and counter tests
  - The only run artifact provided is .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.pcap.sha256, which hashes to e3b0c442… (the SHA-256 of an empty file). This undermines the claim of successful SRv6 capture with SRH and ordered SIDs.
  - No independent proof-of-run artifacts are present to substantiate the required checks:
    - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.txt (textual decode showing SRH and ordered SIDs)
    - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/mysid_counters.before.json (pre-traffic counters)
    - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/mysid_counters.after.json (post-traffic counters showing increment)
    - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/behaviors.leaf-dst.json (End.DT46 VRF verification)
    - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sid_list.leaf-src.json (expected ordered SIDs from headend)
  - As written, the evidence does not independently demonstrate SRH capture, ordered SIDs, decapsulation VRF correctness, or MySID counter increments.

- T051 [US2] Update and delete lifecycle (effect-witness)
  - This criterion requires independently readable, durable effect evidence. The proposer claims specific proof artifacts exist, but the grounding snapshot shows they are missing:
    - Missing: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.default-fabric.txt (cannot verify default-fabric persists after update)
    - Missing: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.sdc-configs.after.txt (cannot observe the post-update SDC Config set)
    - Missing: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.count.before.txt (pre-delete SRv6-owned Config count)
    - Missing: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.count.after.txt (post-delete SRv6-owned Config count)
  - Without these independently readable outputs, the effect-witness obligation is not met. Provide the above files generated from an actual run to prove persistence of shared state and release of SRv6-owned claims/configs.

VERDICT 05be6b5548bd78ee: REJECTED

