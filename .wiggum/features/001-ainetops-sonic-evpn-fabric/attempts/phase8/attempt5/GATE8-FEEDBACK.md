# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

Unmet or unproven acceptance criteria and gaps:

- T073 (Security audit completeness)
  - Grafana plugin provenance and anonymous access: The evidence claims GF_INSTALL_PLUGINS pins grafana-flow-panel by digest and GF_AUTH_ANONYMOUS_ENABLED="false" in deploy/observability/grafana.yaml, but the grounded excerpt does not show these env vars. Provide the manifest lines that set both variables with the pinned plugin reference and anonymous disabled, or add them if missing.
    - NEEDS-GROUNDING: deploy/observability/grafana.yaml

- T079 (Run full test suites)
  - The spec requires running API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 packet-capture/failover, topology-parity, observability, and teardown suites. While test files exist, there is no grounded evidence that these suites were executed and passed. The Makefile’s test target runs only static + envtest; no logs or CI outputs are provided for the broader suites.
  - Actionable: Add Make/CI targets that run each required suite, and publish run logs under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs (e.g., tests.api.log, tests.unit.log, tests.golden.log, tests.sdc-validation.log, tests.integration.log, tests.failure.log, tests.traffic.log, tests.srv6-capture.log, tests.srv6-failover.log, tests.topology-parity.log, tests.observability.log, tests.teardown.log). Ensure they reflect real execution, not placeholders.

- T079a (Assert owned CRD set)
  - scripts/lib/assert_crds.sh exists, but there is no grounded invocation tying it into the workflow. The current scripts/provision.sh excerpt does not show it being called, and the cited proof file scripts.provision.sh.proof.txt does not include such an invocation either.
  - Actionable: Invoke scripts/lib/assert_crds.sh from scripts/provision.sh (or a CI step) so a provision run fails if the AINETOPS-owned CRD set deviates from exactly srv6services.ainetops.io (and migrationplans.ainetops.io only if explicitly allowed). Provide grounded proof of the invocation and a passing/meaningful run output.

- T080 (Cycles, idempotence, partial-state off, conformance cycle, evidence publication)
  - The evidence claims multiple cycle logs and an SC-001..SC-016 evidence index, but these files are missing in the snapshot:
    - .wiggum/.../gates/proofs/cycles/* not shown
    - .wiggum/.../gates/proofs/evidence-index/SC-001..SC-016.txt — MISSING
  - Only the runtime standalone/Compose scan log exists. This does not satisfy the requirement to run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle, nor to publish SC-001..SC-016 evidence (including SRv6 conformance and topology parity).
  - Actionable: Execute and capture:
    - Three full provision→test→off cycles (provision-1/2/3.log, test-*.log, off-1/2/3.log)
    - A second-provision idempotence run (no changes) with logs
    - An off-from-partial-state test with logs
    - A conformance-profile cycle (sonic-vm) with logs
    - Publish an evidence index mapping SC-001..SC-016 with pointers to the concrete artifacts
    - Keep these under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs

Notes on items that appear satisfied:
- T074 [P]: Supply-chain checks are implemented (scripts/ci/supply_chain.sh), Make target exists, images pinned proof present, SR Linux absence artifact present by stat, and README documents srl-telemetry-lab as presentation-only.
- T074a: CI deny-list workflow enforces migration/visualization/placement boundaries with allowed contexts and fails on violations.
- T075 [P]: docs/OPERATORS.md and docs/DEVELOPERS.md cover the required topics, including compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline/topology presentation, recovery, and break-glass finalizer.
- T076: scripts/provision.sh is non-interactive, exposes --profile/--cluster-name/--timeout, orders preflight→network→Kind→containerlab→apps→seed/intent steps, builds/loads/deploys provider and SRv6 controller, runs a capability gate, and fails when sonic-vs is not SRv6-qualified.
- T077: scripts/off.sh supports optional evidence capture, containerlab removal, optional named Kind deletion, owned-network cleanup with label check, generated secret cleanup, and tolerates partial states.
- T078: Make wrappers exist for quickstart, provision, off, lab-qualify, and tests, while keeping scripts/provision.sh and scripts/off.sh as the only lifecycle implementations.

VERDICT f0e52ef69023d737: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `cmd/sonic-provider/Dockerfile`
- `cmd/srv6-controller/Dockerfile`
- `supply-chain.images-pinned.ok.txt`
- `supply-chain.srlinux.ok.txt`
