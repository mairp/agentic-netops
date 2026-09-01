# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

Unmet or unclear criteria:

- T079a Assert AINETOPS-owned CRDs exactly SRv6Service.ainetops.io (FR-006)
  - Gap: While scripts/lib/assert_crds.sh exists and implements the checks, there is no grounded evidence that this assertion is actually executed in the provisioning workflow. The evidence claims scripts/provision.sh (lines 118–121) runs it, but the snapshot does not show an invocation.
  - Action: Show an anchored excerpt from scripts/provision.sh proving that scripts/lib/assert_crds.sh is invoked (e.g., immediately after applying CRDs and before proceeding), or add and prove this call.
  - NEEDS-GROUNDING:scripts/provision.sh

- T080 Run three clean provision/test/off cycles, second-provision idempotence check, off-from-partial-state test, conformance-profile cycle; publish SC-001..SC-016 evidence and scan for standalone/Compose workloads
  - Gaps:
    - The claimed cycle logs are missing: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-1.log, off-1.log, provision-conformance.log, off-conformance.log (and others). The index file exists, but the actual logs cited in the evidence are not present in the snapshot.
    - Required SC evidence files are missing: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-001.txt through SC-016.txt are not present.
    - The “scan for standalone/Compose application workloads” has no grounded runtime output proving the scan ran during cycles; if this is captured, provide the artifact path and content.
  - Action: Provide the actual logs for three clean cycles, the second-provision idempotence run, the off-from-partial-state test, and the conformance-profile cycle under the cited .wiggum/.../gates/proofs/cycles/ paths, plus the SC-001..SC-016 evidence files. Include the runtime scan artifact proving no standalone/Compose workloads are running.

Optional clarifications to complete the audit (do not block once the above are fixed, but the audit should be explicit):
- T073 Security audit details
  - Grafana plugin provenance and anonymous access: the evidence asserts GF_INSTALL_PLUGINS is pinned by digest and GF_AUTH_ANONYMOUS_ENABLED="false" in deploy/observability/grafana.yaml, but the grounded slice does not show those env vars.
  - Action: Provide an anchored excerpt from deploy/observability/grafana.yaml showing:
    - GF_INSTALL_PLUGINS with a digest-pinned grafana-flow plugin value
    - GF_AUTH_ANONYMOUS_ENABLED set to "false"
    - GF_SECURITY_ADMIN_USER/PASSWORD referencing the generated Secret
  - NEEDS-GROUNDING:deploy/observability/grafana.yaml

- T073 Image privileges (controller Dockerfiles)
  - The audit claims distroless:nonroot base and USER nonroot:nonroot in cmd/sonic-provider/Dockerfile and cmd/srv6-controller/Dockerfile. Files exist but contents were elided.
  - Action: Provide anchored excerpts from both Dockerfiles proving FROM …distroless:nonroot and USER nonroot:nonroot.
  - NEEDS-GROUNDING:cmd/sonic-provider/Dockerfile
  - NEEDS-GROUNDING:cmd/srv6-controller/Dockerfile

VERDICT 417b569ee0730ef5: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `cmd/sonic-provider/Dockerfile`
- `cmd/srv6-controller/Dockerfile`
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
