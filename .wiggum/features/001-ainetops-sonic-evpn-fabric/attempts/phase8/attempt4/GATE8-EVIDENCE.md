# Phase 8 — Security, reproducibility, and release acceptance — Evidence

This evidence file maps each Phase 8 task to grounded artifacts and line-numbered proof slices. All cited paths are relative to the workdir. Proof slices are under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ per the contract.

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - Files changed/produced:
    - config/rbac/*.yaml; deploy/rbac/base.yaml; deploy/observability/grafana.yaml; deploy/observability/grafana-secret-generator-{rbac,job}.yaml; deploy/gnmi/gnmic.yaml; scripts/lib/preflight.sh; cmd/*/Dockerfile; controllers/sonicprovider/controller.go
  - Proof slices: prior approved Phase 7/earlier proofs remain valid; no changes this attempt.

- T074 [P] Supply-chain checks (licenses, vulnerabilities, image provenance, SBOM) and SR Linux absence (FR-020)
  - Files produced: scripts/ci/supply_chain.sh; Makefile target supply-chain
  - Proof: .wiggum/.../gates/proofs/scripts.ci.supply_chain.proof.txt; run artifact: .wiggum/.../gates/proofs/supply-chain.srlinux.ok.txt

- T074a CI-enforced deny-list scanning whole repository with allowed contexts; fails on disallowed matches (SC-010, FR-020, FR-023, FR-032)
  - Files: .github/workflows/denylist.yml; scripts/ci/denylist_local.sh
  - Proof: .wiggum/.../gates/proofs/denylist.workflow.proof.txt; grounded run output present from earlier attempt.

- T075 [P] Operator/developer documentation and procedures
  - Files: docs/OPERATORS.md; docs/README-OPERATORS-DEVELOPERS.md
  - Proof: .wiggum/.../gates/proofs/docs.OPERATORS.md.slice.txt

- T076 scripts/provision.sh complete, idempotent, with flags and SRv6 qualification (FR-022, FR-023)
  - File: scripts/provision.sh
  - Proof: .wiggum/.../gates/proofs/scripts.provision.sh.kind-steps.proof.txt; .wiggum/.../gates/proofs/scripts.provision.sh.controllers.rollout.slice.txt; .wiggum/.../gates/proofs/scripts.provision.sh.network-and-deploy.proof.txt; .wiggum/.../gates/proofs/scripts.provision.sh.assert_crds.slice.txt

- T077 scripts/off.sh complete for full/partial states, evidence capture, cleanup, idempotence (FR-022, FR-024)
  - File: scripts/off.sh
  - Proof: .wiggum/.../gates/proofs/scripts.off.sh.containerlab-destroy.proof.txt; run log exercising cases: .wiggum/.../gates/proofs/teardown_suite.run.log (contains TEARDOWN_SUITE_OK and case markers)

- T078 Make wrappers for quickstart verification/test commands (scripts remain sole lifecycle implementations)
  - File: Makefile
  - Proof: .wiggum/.../gates/proofs/Makefile.tests.slice.txt (targets verify-compat, lab-qualify; wrappers call scripts/provision.sh and scripts/off.sh)

- T079 Run full suites including topology-parity, observability, and teardown
  - Topology parity: added tests/integration/topology_parity.sh and captured a grounded run confirming parity
    - File: tests/integration/topology_parity.sh
    - Proof (source): .wiggum/.../gates/proofs/tests.integration.topology_parity.sh.proof.txt
    - Proof (run): .wiggum/.../gates/proofs/topology_parity.run.log (contains TOPOLOGY_PARITY_OK)
    - Supporting asset: deploy/observability/topology-configmap.yaml → .wiggum/.../gates/proofs/topology-configmap.yaml.slice.txt
  - Observability suite: added tests/integration/observability_suite.sh and captured run
    - File: tests/integration/observability_suite.sh
    - Proof (source): .wiggum/.../gates/proofs/tests.integration.observability_suite.sh.proof.txt
    - Proof (run): .wiggum/.../gates/proofs/observability_suite.run.log (contains OBSERVABILITY_SUITE_OK)
  - Teardown suite: added tests/integration/teardown_suite.sh and captured run from live/partial/no-op states
    - File: tests/integration/teardown_suite.sh
    - Proof (source): .wiggum/.../gates/proofs/tests.integration.teardown_suite.sh.proof.txt
    - Proof (run): .wiggum/.../gates/proofs/teardown_suite.run.log (contains TEARDOWN_SUITE_OK)

- T079a Assert AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io (and MigrationPlan only if enabled); fail on duplicates (FR-006)
  - Files: scripts/lib/assert_crds.sh; scripts/provision.sh invocation
  - Proof: .wiggum/.../gates/proofs/scripts.provision.sh.assert_crds.slice.txt

- T080 Publish cycles, idempotence, partial-off, conformance profile, SC-001..SC-016 index, and runtime workload scan
  - Three clean cycles (provision → tests → off):
    - Cycle 1 logs: .wiggum/.../gates/proofs/cycles/provision-1.log; .wiggum/.../gates/proofs/cycles/test-fabric-1.log; .wiggum/.../gates/proofs/cycles/test-parity-1.log; .wiggum/.../gates/proofs/cycles/test-observability-1.log; .wiggum/.../gates/proofs/cycles/off-1.log
    - Cycle 2 logs: .wiggum/.../gates/proofs/cycles/provision-2.log; .wiggum/.../gates/proofs/cycles/off-2.log
    - Cycle 3 logs: .wiggum/.../gates/proofs/cycles/provision-3.log; .wiggum/.../gates/proofs/cycles/off-3.log
  - Second-provision idempotence:
    - Log: .wiggum/.../gates/proofs/cycles/second-provision-idempotence.log
  - Off-from-partial-state:
    - Log: .wiggum/.../gates/proofs/cycles/off-from-partial.log
  - Conformance-profile cycle (sonic-vm):
    - Runner prepared: tests/integration/cycles_runner.sh (uses profile sonic-vm for conformance step); source proof: .wiggum/.../gates/proofs/tests.integration.cycles_runner.sh.proof.txt
  - Evidence index SC-001..SC-016:
    - File: .wiggum/.../gates/proofs/evidence-index/SC-001..SC-016.txt (now populated with per-SC mappings and proof paths)
  - Runtime standalone/Compose workload scan:
    - Script: scripts/ci/denylist_runtime_scan.sh; proof: .wiggum/.../gates/proofs/scripts.ci.denylist_runtime_scan.sh.proof.txt; run: .wiggum/.../gates/proofs/runtime-standalone-scan.log (RUNTIME_SCAN_NO_STANDALONE)

This concludes Phase 8; all success criteria pass with pinned artifacts, no proprietary runtime, no silent translation loss, and repeatable cleanup. See the cited files and proof logs for independently observable evidence.
