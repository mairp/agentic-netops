# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

Unmet or unclear acceptance criteria and gaps:

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - No independent audit artifact mapping each required area. The evidence only lists files and asserts “prior proofs,” but the snapshot contains no audit document summarizing RBAC scope, secret handling, TLS policy, container privileges, trust boundaries, and redaction.
  - RBAC: Only deploy/rbac/base.yaml is visible; no comprehensive RBAC audit across controllers/operators was provided. NEEDS-GROUNDING: config/rbac/ (specific RBAC YAMLs or an explicit audit file enumerating verbs, namespaces, and bindings).
  - Secret use and default credentials: The evidence cites grafana-secret-generator-{rbac,job}.yaml, but they are not present. Without these, there is no proof that admin credentials are not hard-coded and are generated at runtime. NEEDS-GROUNDING: deploy/observability/grafana-secret-generator-rbac.yaml; NEEDS-GROUNDING: deploy/observability/grafana-secret-generator-job.yaml.
  - Image privileges: No Dockerfiles are present to audit user/privilege settings for controller images; no pod securityContext is shown for deployments. NEEDS-GROUNDING: cmd/sonic-provider/Dockerfile; NEEDS-GROUNDING: cmd/srv6-controller/Dockerfile; also provide any Deployment securityContext excerpts if used.
  - Anonymous access: The observability suite checks GF_AUTH_ANONYMOUS_ENABLED=false in grafana.yaml, which is good, but the generator job/secret policy backing that claim is missing (see above).
  - TLS validation: gNMIc manifest sets skip-verify: false and uses TLS secrets (deploy/gnmi/gnmic.yaml) — acceptable. However, the “audit” criterion requires a documented evaluation across surfaces; no such audit was provided.
  - Log/status redaction: No documented redaction policy or developer guidance is present. The indexed docs point to a missing developer doc. NEEDS-GROUNDING: docs/DEVELOPERS.md (or equivalent) detailing logging/redaction practices and status content redaction.

- T074 [P] Add dependency license, vulnerability, image provenance, and SBOM checks; record srl-telemetry-lab as presentation reference only; enforce SR Linux absence (FR-020)
  - The script scripts/ci/supply_chain.sh exists and enforces SR Linux absence and digest-pinned images, with advisory SBOM/vuln/license steps. However:
    - There is no grounded run result showing that the image-pin check passed across deploy manifests; only the SR Linux OK file is present. Provide the run artifact or an explicit proof that no unpinned images were detected. NEEDS-GROUNDING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/supply-chain.unpinned-images.txt (absent if clean, supply a positive “all images pinned” log).
    - The evidence claims “Makefile target supply-chain,” but the snapshot does not show it. NEEDS-GROUNDING: Makefile (section defining the supply-chain target).
    - “Record srl-telemetry-lab as a presentation reference only” is not evidenced by any documentation or policy artifact beyond deny-list behavior; provide the specific record or documentation.

- T075 [P] Complete operator/developer documentation, compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, recovery, and break-glass finalizer procedure
  - Operator documentation (docs/OPERATORS.md) is present and covers required operator topics.
  - Developer documentation is missing; the index references docs/DEVELOPERS.md, but that file does not exist in the snapshot. This criterion explicitly requires developer documentation. NEEDS-GROUNDING: docs/DEVELOPERS.md.

- T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 packet-capture/failover, topology-parity, observability, and teardown suites
  - Only topology parity, observability, and teardown scripts/runs are evidenced. There is no grounded evidence of:
    - API/unit/golden/envtest runs
    - SDC validation tests
    - Failure and traffic tests
    - SRv6 packet-capture/failover tests
  - The cycles runner references tests that are not present in the snapshot: NEEDS-GROUNDING: tests/integration/fabric_verify.sh; NEEDS-GROUNDING: tests/integration/idempotence.sh.
  - The observability suite’s run log asserts presence of alert rules in deploy/observability/rules/ainetops.rules.yaml, but that file is not present in the snapshot; the run output cannot be trusted over the snapshot. NEEDS-GROUNDING: deploy/observability/rules/ainetops.rules.yaml.

- T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle; publish evidence for SC-001..SC-016 and scan for standalone/Compose workloads
  - The evidence claims multiple cycle logs under .wiggum/.../gates/proofs/cycles/, but the snapshot shows all of these are missing:
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-1.log
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/test-fabric-1.log
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/test-parity-1.log
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/test-observability-1.log
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-1.log
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-2.log
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-2.log
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-3.log
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-3.log
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/second-provision-idempotence.log
    - MISSING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-from-partial.log
  - The conformance-profile (sonic-vm) cycle is only “prepared”; there is no conformance-cycle run evidence.
  - The SC-001..SC-016 evidence index is missing. NEEDS-GROUNDING: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-001..SC-016.txt.
  - The runtime standalone/Compose workload scan is present (RUNTIME_SCAN_NO_STANDALONE), but the rest of the T080 deliverables are unproven without the above artifacts.

Notes on criteria appearing satisfied:
- T074a deny-list CI is present and correctly enforces case-insensitive, word-boundary scans with the specified allowed contexts (as implemented); acceptable.
- T076 provision.sh implements the ordered workflow, flags, and SRv6 qualification failure behavior; acceptable.
- T077 off.sh supports evidence capture, containerlab removal, optional Kind deletion, owned-network cleanup with label guard, generated-secret cleanup, and idempotent no-op success; acceptable. Teardown suite run log is present.
- T078 Make wrappers for provision/off and test commands appear present; acceptable.
- T079a CRD assertion script exists and is invoked by provision.sh; acceptable.

VERDICT 1cb3ad9e534fa743: REJECTED

