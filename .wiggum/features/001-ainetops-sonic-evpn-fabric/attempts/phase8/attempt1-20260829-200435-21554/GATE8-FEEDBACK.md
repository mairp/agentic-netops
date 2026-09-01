# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

Unmet or unclear acceptance criteria:

- T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle; publish evidence for SC-001 through SC-016, including mandatory SRv6 conformance and physical/service topology parity, and scan for standalone/Compose workloads
  - Missing cycle artifacts claimed as present. The grounding snapshot shows several cycle logs are absent:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/test-fabric-1.log — MISSING
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/test-parity-1.log — MISSING
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/test-observability-1.log — MISSING
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-1.log — MISSING
  - Additionally, the provided SRv6 capture suite log indicates a tooling/flag failure rather than a successful run: .wiggum/.../tests.srv6-capture.log contains “Error: unknown flag: --tls”. This undercuts the claim of running the SRv6 packet-capture suite as part of the published evidence.
  - Actionable: Supply complete logs for all three clean cycles (provision-1/2/3, test-fabric-1/2/3, test-parity-1/2/3, test-observability-1/2/3, off-1/2/3), the second-provision idempotence, off-from-partial-state, and the full conformance-profile cycle, ensuring the SRv6 capture and failover suites run without CLI errors. Also include explicit SC-001..SC-016 evidence references within these artifacts, and retain the runtime scan log proving no standalone/Compose workloads.

VERDICT 2b1c1a2ff019fcf4: REJECTED



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
