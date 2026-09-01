# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

Unmet or unclear criteria and gaps:

- T079a Assert that the installed AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io (and, only if enabled, MigrationPlan.ainetops.io); fail on duplicate fabric/device-config CRDs
  - The enforcement script exists and implements the checks (scripts/lib/assert_crds.sh is grounded with the required logic), but there is no grounded evidence that the assertion is actually invoked in the workflow. The evidence claims scripts/provision.sh calls it “immediately after applying the SRv6 CRD,” but the grounded provision.sh excerpt does not show such an invocation, and no other grounded artifact shows it being executed.
  - Actionable gap: Provide grounded proof (anchored lines) in scripts/provision.sh showing the call to scripts/lib/assert_crds.sh, or equivalent CI/test invocation that fails the run on violation.
  - NEEDS-GROUNDING:scripts/provision.sh

- T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle; publish evidence for SC-001 through SC-016, including mandatory SRv6 conformance and physical/service topology parity, and scan for standalone/Compose application workloads
  - The cycles runner script exists (tests/integration/cycles_runner.sh), but the grounded snapshot does not include the published cycle logs it claims (e.g., provision-1.log, test-fabric-1.log, …, off-conformance.log, runtime-inventory-*.log) under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/. Unlike the elision note for other files, there is no “verified present” stat entry for these cycle logs.
  - Also, the “runtime inventory” step in cycles_runner.sh only collects kubectl get pods -A and helm list -A; it does not capture host-level container inventory (e.g., docker ps) to positively assert the absence of standalone/Compose application workloads at runtime. If this is intended to satisfy the “scan for standalone/Compose application workloads” part, expand the scan or provide grounded logs proving the absence.
  - Actionable gaps:
    - Provide the grounded directory listing and contents (or anchored slices) of the cycle logs under .wiggum/.../gates/proofs/cycles/ proving the three clean cycles, idempotence re-provision, off-from-partial, and the conformance-profile cycle were run.
    - Augment and ground the runtime scan evidence to include host-level container inventory, or otherwise provide a grounded assertion that no standalone/Compose application workloads were running.
  - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/

VERDICT 3db6fba3e168433f: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `cmd/sonic-provider/Dockerfile`
- `cmd/srv6-controller/Dockerfile`
- `supply-chain.images-pinned.ok.txt`
- `supply-chain.srlinux.ok.txt`
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
