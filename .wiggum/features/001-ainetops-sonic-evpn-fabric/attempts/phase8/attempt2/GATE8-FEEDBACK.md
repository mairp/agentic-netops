# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

Unmet or unclear acceptance criteria:

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - Image privileges: The evidence asserts controller images run as non-root, but no grounded excerpt shows USER nonroot or base images. Provide anchored excerpts proving non-root runtime for both Dockerfiles.
    - NEEDS-GROUNDING:cmd/sonic-provider/Dockerfile
    - NEEDS-GROUNDING:cmd/srv6-controller/Dockerfile

- T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 packet-capture/failover, topology-parity, observability, and teardown suites
  - Only the capability gate log (qualify.run.log) is grounded. There is no grounded evidence that API/unit/golden/envtest ran (e.g., go test output), no SDC validation test logs, and no execution logs for the listed integration/failure/traffic/SRv6 capture/failover/topology-parity/observability/teardown suites. The mere claim that scripts exist is insufficient.
  - Provide CI/run artifacts under .wiggum/.../gates/proofs/ showing each suite executed and passed (per-suite logs and a summary), or grounded test reports (e.g., junit/json) covering:
    - API/unit/golden/envtest
    - SDC validation
    - Integration: EVPN traffic, MTU/ECMP, SRv6 capture/counters, failover/path-change, drift/update/delete/idempotence, topology parity, observability, teardown

- T079a Assert that the installed AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io (and, only if enabled by T060, MigrationPlan.ainetops.io); fail if duplicate fabric/device-config CRDs are present (FR-006)
  - scripts/lib/assert_crds.sh exists and enforces the rule, but there is no grounded evidence it is invoked during provisioning or test runs. Either:
    - Provide a grounded anchored excerpt showing scripts/provision.sh calls scripts/lib/assert_crds.sh, or
      - NEEDS-GROUNDING:scripts/provision.sh
    - Provide a run log proving the check executed and passed (e.g., a proof file containing “[assert-crds] OK” with the found CRDs).

- T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle where applicable; publish evidence for SC-001 through SC-016, including mandatory SRv6 conformance and physical/service topology parity, and scan for standalone/Compose application workloads
  - There is no grounded evidence of:
    - Three clean provision/test/off cycles (no provision/off logs for cycle 1–3).
    - A second-provision idempotence run log (only the idempotence.sh script is present; no before/after artifact files or pass assertion logs are grounded).
    - An off-from-partial-state test execution/logs.
    - A conformance-profile (sonic-vm) cycle execution/logs.
    - Published evidence mapping SC-001 through SC-016 (including physical/service topology parity) to concrete proof artifacts.
  - Provide CI/run artifacts under .wiggum/.../gates/proofs/ that include:
    - provision-1.log, test-1.log, off-1.log; provision-2.log, test-2.log, off-2.log; provision-3.log, test-3.log, off-3.log
    - idempotence before/after snapshots and a passing diff assertion
    - off-from-partial-state test logs
    - one sonic-vm conformance cycle logs (provision/test/off)
    - an SC-001..SC-016 evidence index mapping each SC to its proof files
    - A grounded result from the denylist workflow run (or local equivalent) demonstrating the standalone/Compose scan at the time of the cycles

VERDICT 2ae6ff8d597bbb8d: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `cmd/sonic-provider/Dockerfile`
- `cmd/srv6-controller/Dockerfile`
- `deploy.rbac.secrets.yaml.slice.txt`
- `qualify.report.json`
- `scripts.provision.sh.kind-steps.proof.txt`
