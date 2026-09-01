# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

Unmet or unclear acceptance criteria

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - The audit document is inaccurate versus the grounded RBAC manifests. docs/SECURITY_AUDIT_T073.md states the provider ClusterRole extends read/watch only to SDC Targets/status, but config/rbac/cluster_role.yaml grants create, patch, update, and delete on sdc.sdcio.dev targets. This contradicts the “least privilege” claim and makes the audit unreliable. Action: either tighten the ClusterRole to match the least-privilege claim or correct the audit to match the actual verbs and justify target write/delete privileges.

- T074a Add a CI-enforced deny-list with allowed contexts only; fail build on any match outside allowed context (SC-010, FR-020, FR-023, FR-032)
  - The provided proof slice only shows the scoped exception logic for srl-telemetry-lab. It does not show the full deny-list patterns for required terms (e.g., cisco, crosswork, nso, cnc, proprietary ned(s), ai-network-services-devnet-2606, devnet-2606, docker-compose/docker compose/compose.yaml/compose.yml, standalone container/deployment, sr linux/srlinux/nokia_srlinux) nor the failure behavior for those matches. NEEDS-GROUNDING:.github/workflows/denylist.yml

- T076 Complete scripts/provision.sh workflow; fail when the selected SONiC profile is not SRv6-qualified (FR-022, FR-023)
  - scripts/provision.sh enforces the SRv6 capability gate only if scripts/lib/qualify.sh exists and is executable. In the grounded snapshot, scripts/lib/qualify.sh is not present, so the required gate is not enforced and the script will not fail when the selected profile is not SRv6-qualified. Provide the gate implementation and ensure it is always invoked. NEEDS-GROUNDING:scripts/lib/qualify.sh

- T078 Add Make wrappers for quickstart verification/test commands while keeping provision.sh and off.sh as the only lifecycle implementations
  - The Makefile content is not present in the snapshot, so the required wrappers and their delegation to the scripts cannot be verified. NEEDS-GROUNDING:Makefile

- T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle; publish evidence for SC-001 through SC-016; scan for standalone/Compose workloads
  - The cycles index file lists many expected logs, but the actual cycle logs (e.g., cycles/provision-1.log, off-1.log, provision-conformance.log) are not present in the snapshot. NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-1.log
  - The required SC evidence files are missing. NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-001.txt (and SC-002..SC-016)

VERDICT 7505cbd761dcf3b8: REJECTED



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
