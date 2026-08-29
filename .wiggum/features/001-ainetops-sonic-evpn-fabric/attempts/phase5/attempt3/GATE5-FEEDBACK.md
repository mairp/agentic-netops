# Phase 5 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE5-EVIDENCE.md:

Unmet or unclear criteria:

- T041a Build and deploy SRv6 controller; verify Pod/Service/probes/RBAC; gate SRv6 tests on health
  - RBAC mismatch: the Deployment uses serviceAccountName: ainetops-srv6-controller (deploy/ainetops/manifests/srv6-controller.yaml) but the ClusterRoleBinding in deploy/rbac/srv6-crd-rbac.yaml binds to ServiceAccount name: ainetops-controller (namespace ainetops-system). This does not grant the controller Pod the intended CRD permissions. Provide a corrected RoleBinding subject matching the Deployment’s ServiceAccount, and include an independent kubectl auth can-i or API access evidence from the running Pod.
  - Health gate not enforced: scripts/provision.sh calls rollout status for ainetops-srv6-controller with “|| true”, which allows proceeding even if the controller is not Ready. The criterion requires not proceeding to SRv6 service tests until the controller is healthy. Replace “|| true” with a hard gate (nonzero exit on failure) and include proof of the enforced gate.

- T047b Implement SRv6 capture and counter tests: capture outer IPv6/SRH with ordered SIDs, verify egress decapsulation into intended VRF, assert MySID counter increments
  - Missing durable pcap identity proof: the evidence claims .wiggum/.../gates/proofs/srv6_outer_srh.pcap.sha256 exists, but the grounding snapshot shows it is missing. A criterion “proven” only by a claimed file that isn’t present is not met. Either provide the actual generated sha256 file from a run, or remove the claim and add another independently observable artifact demonstrating capture occurred.
  - Ordered SID verification is weakened by a fallback that only asserts SRH presence when the SID list cannot be discovered. The criterion requires verifying ordered SIDs in the SRH. Add a deterministic source for expected SIDs (or a robust extraction) and fail the test if ordering cannot be verified; include proof slices showing the ordered match from a run.

- T051 Update and delete lifecycle tests; effect-witness
  - No independently readable durable effect is shown for update/delete runs. The script writes proof files (e.g., .wiggum/.../update.sdc-configs.after.txt, delete.srv6-configs.count.before/after.txt), but there is no grounded snapshot of these outputs demonstrating the effect occurred through an independent read path. Provide the captured artifacts from an actual run showing:
    - default-fabric still present after update and delete;
    - SDC Config set before/after delete with SRv6-owned entries reduced;
    - Any durable IDs/counts or content hashes that could not exist before the action.

If you believe any of these judgments require file content not included in the snapshot, provide the following:
- NEEDS-GROUNDING:config/samples/ainetops_v1alpha1_srv6service.yaml (referenced by tests, to confirm SRv6 sample exists)
- NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.sdc-configs.after.txt (effect-witness for T051)
- NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.count.before.txt
- NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.count.after.txt
- NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.pcap.sha256

VERDICT 89cce75ce46feed2: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./Dockerfile`) or state in your evidence that grounding cannot reach it:
- `cmd/srv6-controller/Dockerfile`
