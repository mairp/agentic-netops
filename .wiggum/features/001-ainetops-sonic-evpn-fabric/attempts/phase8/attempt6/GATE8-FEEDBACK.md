# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

Unmet or unclear acceptance criteria:

- T078 Make wrappers for quickstart verification/test commands
  - Missing evidence: The Makefile content is not present in the grounding snapshot. The evidence claims quickstart/provision/off/lab-qualify/suites/test-all targets exist, but without the Makefile we cannot independently verify these wrappers.
  - Action: Provide the Makefile content showing the required targets and that provision/off remain the only lifecycle implementations.
  - NEEDS-GROUNDING:Makefile

- T079a Assert AINETOPS-owned CRDs and fail on duplicate fabric/device-config CRDs (FR-006)
  - Partial implementation: scripts/lib/assert_crds.sh asserts that AINETOPS-owned CRDs equal exactly srv6services.ainetops.io (and optionally migrationplans.ainetops.io when enabled). This covers the first part but does not implement the “fail if duplicate fabric/device-config CRDs are present” requirement.
  - What’s missing: An explicit check that there are no duplicate fabric/device-config CRDs installed (e.g., multiple versions or conflicting CRD groups relevant to Kubenet/KUID/SDC/device-config). The current script filters only ainetops.io; it does not detect duplicates in the broader CRD set.
  - Action: Extend assert_crds.sh to scan the cluster’s CRD list and fail if duplicate or conflicting fabric/device-config CRDs are present (per FR-006), and add a proof slice or test log demonstrating the check.

- T080 Run three clean provision/test/off cycles, second-provision idempotence, off-from-partial, conformance cycle; publish SC-001..SC-016 evidence and runtime scan
  - Missing artifacts: The cycles evidence index exists (.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T080.cycles.index.txt), but the referenced cycle logs (e.g., cycles/provision-1.log, cycles/off-1.log, …) are not present in the snapshot. Without the actual logs, we cannot verify the cycles ran or that outputs were captured.
  - Also missing: The SC-001..SC-016 evidence files are absent; the snapshot shows “.wiggum/.../proofs/evidence-index/SC-001.txt — MISSING”.
  - Action: Provide the actual cycle log files listed in the index under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/ and the SC-001..SC-016 evidence files referencing grounded proofs for each success criterion.
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-1.log
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-1.log
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-2.log
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-2.log
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-3.log
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-3.log
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/second-provision-idempotence.log
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-from-partial.log
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-conformance.log
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-conformance.log
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-001.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-002.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-003.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-004.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-005.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-006.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-007.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-008.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-009.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-010.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-011.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-012.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-013.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-014.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-015.txt
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-016.txt

Notes on other criteria:
- T073: Evidence is grounded for RBAC verbs/scopes, in-cluster Secret generation, gNMIc TLS validation (skip-verify: false with Secret-mounted TLS), controller Pod securityContext, KVM gating, Grafana plugin provenance pinned by digest with anonymous access disabled, and redaction guidance in docs. No contradiction found in the snapshot.
- T074: scripts/ci/supply_chain.sh enforces SR Linux absence and digest-pinned images; advisories for govulncheck/SBOM/licenses are present. Meets the criterion.
- T074a: .github/workflows/denylist.yml runs case-insensitive, word-boundary scans across the repo with the specified allowed contexts and fails on violations. Meets the criterion.
- T075: docs/OPERATORS.md and docs/DEVELOPERS.md cover the requested topics (compatibility matrix, sizing, image acquisition, EVPN/SRv6 limits, telemetry, topology, recovery, break-glass; and developer RBAC/redaction/reproducibility). Meets the criterion.
- T076: scripts/provision.sh exposes profile/name/timeout flags, runs preflight, ensures mgmt network, Kind attach, containerlab deploy, installs in-cluster apps, applies SDC seed, invokes a capability gate, and includes the CRD assertion call site. Meets the criterion.
- T077: scripts/off.sh supports evidence capture, containerlab destroy, optional Kind deletion, owned network cleanup with label guard, generated-secret cleanup, and repeatable no-op success. Meets the criterion.
- T079: Suite logs are indexed and the individual tests.*.log files are verified present by stat; run_suites.sh captures and publishes logs. Meets the criterion.

Because T078, T079a, and T080 are unmet or unclear, the phase cannot be approved.

VERDICT eb46e3e18256d38b: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `cmd/sonic-provider/Dockerfile`
- `cmd/srv6-controller/Dockerfile`
- `tests.api.log`
- `tests.failure.log`
- `tests.golden.log`
- `tests.integration.log`
- `tests.observability.log`
- `tests.sdc-validation.log`
- `tests.srv6-capture.log`
- `tests.srv6-failover.log`
- `tests.teardown.log`
- `tests.topology-parity.log`
- `tests.traffic.log`
- `tests.unit.log`
