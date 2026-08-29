# Phase 5 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE5-EVIDENCE.md:

Unmet or unclear criteria:

- T041a Build the T026a SRv6 service controller binary, load it, and deploy it inside Kind; verify Pod/Service/probes/RBAC; do not proceed to SRv6 service tests until the controller is healthy
  - Missing independent RBAC verification. You showed deploy/rbac/srv6-crd-rbac.yaml and the ServiceAccount in deploy/rbac/base.yaml, but there is no cluster read proving the ClusterRole and ClusterRoleBinding exist and are bound to the ServiceAccount. Provide kubectl get -o yaml (or equivalent) for:
    - ClusterRole ainetops-srv6-controller-crd
    - ClusterRoleBinding ainetops-srv6-controller-crd
    - ServiceAccount ainetops-srv6-controller (namespaced ainetops-system)
    Capture these under .wiggum/.../gates/proofs/.
  - Health gating is asserted implicitly via rollout, but your grounded scripts/provision.sh slice shows earlier use of rollout status with “|| true” and short timeouts; ensure your current script (the one actually run) hard-fails if the SRv6 controller is not Ready and capture a proof of health probes responding (curl to /healthz and /readyz via port-forward or logs showing readiness) before any SRv6 service tests execute. Provide a proof artifact (e.g., .wiggum/.../srv6-controller.health.txt) that shows the probes succeeding.

- T047b [US5] Implement SRv6 capture and counter tests: capture outer IPv6/SRH with ordered SIDs, verify egress decapsulation into the intended VRF, and assert MySID counter increments
  - The provided pcap is not credible: .wiggum/.../srv6_outer_srh.pcap is 31 bytes and contains “pcapdummycontentwithipv6srh”, which is not a real capture. This does not substantiate an actual SRH capture. Replace with a real pcap captured from the source client and include its sha256 (already anticipated as srv6_outer_srh.pcap.sha256).
  - The counter increment evidence is incomplete: mysid_counters.after.json is not present in the snapshot. Provide both before and after counter files and a proof of the increment (your script already computes the sum; capture its stdout/stderr or a dedicated summary file).
  - Decapsulation VRF proof is present (behaviors.leaf-dst.json), but you must show the full chain for one run: capture started, traffic sent, capture stopped, SRH SID order verified, counters before/after, and VRF match. Include a single consolidated run log (e.g., .wiggum/.../srv6_capture_counters.run.log) that references the exact artifact filenames produced in that run.

VERDICT f65027513daa4fec: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./Dockerfile`) or state in your evidence that grounding cannot reach it:
- `cmd/srv6-controller/Dockerfile`
- `delete.default-fabric.hash.before.txt`
- `delete.srv6-configs.removed.txt`
- `srv6_outer_srh.pcap.sha256`
- `update.sdc-configs.before.txt`
- `update.srv6service.annotations.diff.txt`
