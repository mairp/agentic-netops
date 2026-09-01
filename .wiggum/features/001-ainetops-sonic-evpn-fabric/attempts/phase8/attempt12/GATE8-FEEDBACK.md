# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

REJECTED criteria and gaps to address:

- T080 Run three clean provision/test/off cycles, idempotence, off-from-partial, conformance cycle; publish SC-001..SC-016 evidence; scan for standalone/Compose workloads
  - Missing cycle evidence: the snapshot shows the cited cycle logs are not present. For example, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-1.log is MISSING (and other cycle logs are likewise absent). Produce all required logs:
    - provision-{1,2,3}.log; test-fabric-{1,2,3}.log; test-parity-{1,2,3}.log; test-observability-{1,2,3}.log; off-{1,2,3}.log
    - second-provision-idempotence.log; off-from-partial.log
    - provision-conformance.log; test-fabric-conformance.log; test-parity-conformance.log; test-observability-conformance.log; off-conformance.log
  - Final checkpoint not met: suite logs show multiple failures (not just runs). Examples from grounded logs:
    - tests.integration.log: BGP session-state assertions failed (“expected ‘ESTABLISHED’…”) and “Error: unknown flag: --tls”
    - tests.traffic.log: “No such container: clab-ainetops-fabric-client01”
    - tests.srv6-capture.log: “Error: unknown flag: --tls”
    - tests.srv6-failover.log: “Unknown command ‘link’ for ‘containerlab’” and alert not observed
    - tests.topology-parity.log: missing test input file and unbound variable
    - tests.observability.log: Grafana Flow plugin not detected as pinned by digest in test path
    - tests.teardown.log: teardown test failing due to missing referenced test path
  These contradict the “Final checkpoint: All success criteria pass … and repeatable cleanup.” Provide passing runs (or fix the test harness to target the implemented paths) and publish the corresponding passing evidence.

- T079a Assert installed AINETOPS-owned CRDs exactly match SRv6Service.ainetops.io; fail on duplicates (FR-006)
  - The run artifact shows “[assert-crds] OK: AINETOPS-owned CRDs = srv6services.ainetops.io,” and provision.sh invokes the check. However, the enforcement of “fail if duplicate fabric/device-config CRDs are present” is not independently observable in the snapshot due to elided content.
  - NEEDS-GROUNDING:scripts/lib/assert_crds.sh
    Provide the relevant portion(s) of scripts/lib/assert_crds.sh showing:
    - the owned_want restriction (srv6services.ainetops.io, plus MigrationPlan only if T060 enabled), and
    - explicit failing checks for duplicate fabric/device-config CRD groups (Kubenet/KUID/SDC ownership conflicts), with exit 1 on violation.

VERDICT 4eb388c4304e5b40: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `assert-crds.run.log`
- `cmd/sonic-provider/Dockerfile`
- `cmd/srv6-controller/Dockerfile`
- `github.workflows.denylist.yml.full.txt`
- `github.workflows.denylist.yml.patterns.slice.txt`
- `github.workflows.denylist.yml.slice.txt`
- `scripts.lib.assert_crds.sh.slice.txt`
- `scripts.off.sh.containerlab-destroy.proof.txt`
- `supply-chain.images-pinned.ok.txt`
- `supply-chain.srlinux.ok.txt`
- `tests.api.log`
- `tests.failure.log`
- `tests.golden.log`
- `tests.integration.cycles_runner.sh.proof.txt`
- `tests.integration.log`
- `tests.observability.log`
- `tests.sdc-validation.log`
- `tests.srv6-capture.log`
- `tests.srv6-failover.log`
- `tests.teardown.log`
- `tests.topology-parity.log`
- `tests.traffic.log`
- `tests.unit.log`
