# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

REJECTED — unmet or unproven acceptance criteria. The items below name the exact gaps to fix.

- T073 Audit RBAC/Secrets/TLS/privileges/trust boundaries/Grafana/anonymous/default credentials/redaction (FR-015)
  - Default credentials mitigation for Grafana is not proven. The snapshot shows GF_AUTH_ANONYMOUS_ENABLED="false" and a generator Job creating a grafana-admin Secret, but there is no grounded excerpt showing Grafana actually consumes that Secret (e.g., GF_SECURITY_ADMIN_USER / GF_SECURITY_ADMIN_PASSWORD env vars via secretKeyRef). Provide an anchored excerpt from deploy/observability/grafana.yaml proving the Secret is wired to Grafana.
    - NEEDS-GROUNDING: deploy/observability/grafana.yaml
  - The prose-only proof file references controllers/sonicprovider/controller.go as evidence of log/status redaction but no grounded excerpt is provided. Either add anchored proof slices showing no secret values are logged or replace this with a concrete audit section in docs that cites the exact code paths and patterns enforced.

- T074 [P] Supply-chain checks and SR Linux absence; record srl-telemetry-lab as a presentation reference only (FR-020)
  - The supply-chain script enforces SR Linux absence and image digests and runs advisory SBOM/vuln/license checks — OK. However, there is no grounded record documenting “srl-telemetry-lab” as a presentation/visualization reference only with no runtime dependency, as required. Add this record to a repo doc (e.g., docs/RESEARCH.md or docs/OPERATORS.md) and cite it in the evidence.
    - Provide the path and anchored excerpt that contains this statement.

- T074a CI-enforced deny-list with only the specified allowed contexts (SC-010, FR-020, FR-023, FR-032)
  - The GitHub Action unconditionally filters out all matches of “srl-telemetry-lab” (filter_allowed strips it globally). This violates the spec: mentions must be allowed only in the specified allowed contexts (Scope-and-interpretation section in spec.md, SC-010, citations in research.md and REVERSE.md). Fix the workflow to allow “srl-telemetry-lab” only in those contexts, not everywhere.
    - File to fix: .github/workflows/denylist.yml (restrict the srl-telemetry-lab exception to the allowed paths/line ranges)
  - Ensure the allowed-context set exactly matches the spec (include SC-010 if applicable). The current filter does not account for SC-010 at all.

- T076 Complete scripts/provision.sh workflow with readiness and SRv6 service stage (FR-022, FR-023)
  - The script’s ordered phases exist and the SRv6 qualification gate is enforced — OK. Missing pieces:
    - No readiness gates are shown. Add explicit waits (kubectl wait/rollout status) for all in-cluster applications (Kubenet/KUID, SDC components, provider, SRv6 controller, gNMIc, OTel Collector, Prometheus, Grafana) and seed resources to reach Ready/Available before proceeding.
    - No SRv6Service instance is applied; only the CRD is applied. Add the step that applies a sample SRv6Service and waits for SRv6 readiness, or document why it is intentionally omitted at this phase and provide alternative readiness checks per spec.
    - The “generated topology assets” step is a placeholder comment. Either invoke the actual generation (e.g., containerlab.sh inspect producing the topology ConfigMap) or apply the generated asset and prove it.
  - Provide anchored proof slices from scripts/provision.sh showing these waits and apply steps.

- T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 packet-capture/failover, topology-parity, observability, and teardown suites
  - The runner script exists but there is no grounded evidence that these suites were actually executed (no tests.*.log files are shown in the snapshot), and parts of the runner are truncated. Provide the logs for each suite under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ demonstrating that the suites ran (even if some are skipped for environment reasons, the run-and-result must be logged).
    - Provide or regenerate: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.api.log, tests.unit.log, tests.golden.log, tests.sdc-validation.log, tests.integration.log, tests.failure.log, tests.traffic.log, tests.srv6-capture.log, tests.srv6-failover.log, tests.topology-parity.log, tests.observability.log, tests.teardown.log (or the exact names your script produces).

- T080 Three clean cycles, idempotence, off-from-partial, conformance profile, SC-001..SC-016 evidence, standalone/Compose scan
  - The “cycles” logs in the snapshot show preflight failures (kind version mismatch) at the start of every provision attempt, so these are not “clean” provision/test/off cycles. Fix the environment and provide successful logs for:
    - Three clean provision/test/off cycles;
    - A second-provision idempotence check (showing no changes);
    - An off-from-partial-state run (already present) and;
    - One conformance-profile cycle.
  - The SC-001..SC-016 evidence-index files are claimed but not grounded in the snapshot. Provide the evidence index files and the cited proof slices.
    - NEEDS-GROUNDING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/
  - The runtime scan is present and passes — OK.

VERDICT d8b6eb49270a620e: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
