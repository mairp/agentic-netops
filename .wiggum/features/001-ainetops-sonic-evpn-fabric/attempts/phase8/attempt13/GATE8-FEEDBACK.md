# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

Unmet or unclear criteria and required fixes

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - Image privileges: The evidence asserts the controller images use distroless:nonroot and set USER nonroot, but the snapshot does not show the Dockerfile contents. Provide anchored excerpts proving non-root runtime and distroless base for both images.
    - NEEDS-GROUNDING:cmd/sonic-provider/Dockerfile
    - NEEDS-GROUNDING:cmd/srv6-controller/Dockerfile
  - Grafana plugin provenance and anonymous access: The audit must show the Flow plugin is pinned by digest and anonymous auth is disabled. Provide the exact env settings in the deployment manifest (e.g., GF_INSTALL_PLUGINS with grafana-flow-panel@sha256:… and GF_AUTH_ANONYMOUS_ENABLED set to "false") as anchored lines.
    - NEEDS-GROUNDING:deploy/observability/grafana.yaml

- T074 [P] Add dependency license, vulnerability, image provenance, and SBOM checks; record srl-telemetry-lab as a presentation reference only and verify no SR Linux runtime artifact enters the dependency graph
  - Presentation-only reference: The provided proof slice for README is a command stub, not a content excerpt. Provide the actual anchored README lines that record srl-labs/srl-telemetry-lab as a visualization/presentation reference only, with no runtime dependency.
    - NEEDS-GROUNDING:README.md

- T079a Assert that the installed AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io (and, only if enabled by T060, MigrationPlan.ainetops.io); fail if duplicate fabric/device-config CRDs are present (FR-006)
  - The enforcement logic is not visible. Provide the relevant parts of scripts/lib/assert_crds.sh showing:
    - the owned_want restriction to srv6services.ainetops.io (and migrationplans.ainetops.io only if AINETOPS_ALLOW_MIGRATIONPLAN=true), and
    - explicit duplicate/conflicting CRD checks across Kubenet/KUID/SDC groups with exit 1 on violation.
    - NEEDS-GROUNDING:scripts/lib/assert_crds.sh

- T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle; publish evidence for SC-001 through SC-016, including mandatory SRv6 conformance and physical/service topology parity; scan for standalone/Compose application workloads
  - The cycles evidence is missing. The snapshot shows only runtime-inventory logs under .wiggum/.../proofs/cycles/ and none of the required cycle logs. Produce all required logs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/
      - provision-1.log; test-fabric-1.log; test-parity-1.log; test-observability-1.log; off-1.log
      - provision-2.log; test-fabric-2.log; test-parity-2.log; test-observability-2.log; off-2.log
      - provision-3.log; test-fabric-3.log; test-parity-3.log; test-observability-3.log; off-3.log
      - second-provision-idempotence.log; off-from-partial.log
      - provision-conformance.log; test-fabric-conformance.log; test-parity-conformance.log; test-observability-conformance.log; off-conformance.log
  - Final checkpoint: Absent the above passing cycles and conformance evidence, the “All success criteria pass with pinned artifacts… and repeatable cleanup” checkpoint is not met.

VERDICT 261beca3f44a8939: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `cmd/sonic-provider/Dockerfile`
- `cmd/srv6-controller/Dockerfile`
- `scripts.lib.assert_crds.sh.slice.txt`
- `scripts.lib.containerlab.sh.proof.txt`
- `scripts.provision.sh.proof.txt`
- `supply-chain.images-pinned.ok.txt`
- `supply-chain.srlinux.ok.txt`
- `tests.api.log`
- `tests.failure.log`
- `tests.golden.log`
- `tests.integration.log`
- `tests.integration.sonic_gnmi_suite.sh.proof.txt`
- `tests.integration.srv6_capture_counters.sh.slice.txt`
- `tests.integration.srv6_failover_path_change.sh.slice.txt`
- `tests.observability.log`
- `tests.sdc-validation.log`
- `tests.srv6-capture.log`
- `tests.srv6-failover.log`
- `tests.teardown.log`
- `tests.topology-parity.log`
- `tests.traffic.log`
- `tests.unit.log`
