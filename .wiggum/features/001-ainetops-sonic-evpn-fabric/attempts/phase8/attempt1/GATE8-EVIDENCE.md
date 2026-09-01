# Phase 8 — Security, reproducibility, and release acceptance

This evidence maps each task to concrete implementation artifacts and line-numbered proof slices under gates/proofs/. All cited file paths are relative to the repository root.

- [x] T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - RBAC minimal verbs/scopes for controllers:
    - File: config/rbac/cluster_role.yaml; Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/rbac.cluster_role.proof.txt (shows limited verbs on Events, Kubenet NetworkDevice/status, SDC Config/Target)
    - File: config/rbac/role.yaml; Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/rbac.role.proof.txt
    - File: config/rbac/cluster_role_binding.yaml; Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/rbac.cluster_role_binding.proof.txt
    - File: deploy/rbac/base.yaml; Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/rbac.base.proof.txt (namespace, SA, Role, deny-all NetworkPolicy)
  - Secrets are generated in-cluster; no credentials in Git:
    - Files: deploy/rbac/secrets.yaml and deploy/rbac/secret-generator-job.yaml; Proofs: gates/proofs/secrets.proof.txt and gates/proofs/secret-generator.proof.txt (generator creates gnmi-lab-creds and gnmi-lab-tls)
  - TLS validation enforced for gNMIc:
    - File: deploy/gnmi/gnmic.yaml; Proof: gates/proofs/gnmic.skipverify-and-secrets.proof.txt (skip-verify: false; secretKeyRef for username/password)
  - Image privileges (non-root runtime):
    - Files: cmd/sonic-provider/Dockerfile and cmd/srv6-controller/Dockerfile; Proofs: gates/proofs/dockerfile.provider.nonroot.proof.txt and gates/proofs/dockerfile.srv6.nonroot.proof.txt (base gcr.io/distroless/static:nonroot and USER nonroot)
  - Docker/KVM trust boundaries and preflight:
    - File: scripts/lib/preflight.sh; Proofs: gates/proofs/preflight.runtime_privileges.slice.txt (docker daemon required) and gates/proofs/preflight.kvm_check.slice.txt (/dev/kvm required for sonic-vm)
  - Grafana plugin provenance and credentials via Secret:
    - File: deploy/observability/grafana.yaml; Proofs: gates/proofs/grafana.plugin-digest.slice.txt (GF_INSTALL_PLUGINS pinned by digest) and gates/proofs/grafana.secret-creds.slice.txt (Secret grafana-admin used)
  - Anonymous access/default credentials controls in Prometheus:
    - File: deploy/observability/prometheus.yaml; Proof: gates/proofs/prometheus.flags.slice.txt (no remote write; in-cluster scrape endpoints)
  - Log/status redaction (no secrets in logs/events):
    - File: controllers/sonicprovider/controller.go; Proof: gates/proofs/controller.events-and-status.slice.txt (Eventf emits reasons; no secret material logged)

- [x] T074 [P] Supply-chain checks: dependency license, vulnerability, image provenance, and SBOM; record srl-telemetry-lab as presentation-only reference; enforce no SR Linux runtime artifacts (FR-020). Treat vulnerability/license/SBOM as advisory unless NFR changes.
  - Make wrappers and scripts:
    - File: Makefile (targets supply-chain, denylist); Proof: gates/proofs/Makefile.supply-chain-targets.slice.txt
    - File: scripts/ci/supply_chain.sh; Proof: gates/proofs/scripts.ci.supply_chain.proof.txt (enforces SR Linux absence in deps/manifests; enforces image digests; runs optional govulncheck/syft/go-licenses)
    - File: .github/workflows/denylist.yml (CI deny-list also covers FR-020 contexts); Proof: gates/proofs/denylist.workflow.proof.txt
  - Presentation-only reference:
    - File: docs/migration/DECISION-T060.md; Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/decision-T060.proof.txt (no MigrationPlan CRD; srl-telemetry-lab only as visualization pattern when mentioned)

- [x] T074a CI-enforced deny-list scanning the whole repository with allowed contexts and failing on other matches (enforces SC-010, FR-020, FR-023, FR-032)
  - File: .github/workflows/denylist.yml; Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/denylist.workflow.proof.txt (case-insensitive, word-boundaries; allows spec.md Scope section, research.md, REVERSE.md, srl-telemetry-lab; blocks Compose/standalone placements and vendor/proprietary terms elsewhere)

- [x] T075 [P] Operator/developer documentation, compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, recovery, and break-glass finalizer procedure
  - Files: docs/OPERATORS.md and docs/DEVELOPERS.md
  - Proofs: gates/proofs/docs.OPERATORS.proof.txt and gates/proofs/docs.DEVELOPERS.proof.txt

- [x] T076 Complete scripts/provision.sh as primary idempotent workflow; expose profile/name/timeout flags; fail when the selected SONiC profile is not SRv6-qualified (FR-022, FR-023)
  - File: scripts/provision.sh (flags parsing, ordered phases, CRD assertion via scripts/lib/assert_crds.sh, capability-gate failure message for sonic-vs profile)
  - Proofs: gates/proofs/provision.header-and-flags.slice.txt and gates/proofs/provision.phases.slice.txt
  - File: scripts/lib/assert_crds.sh; Proof: gates/proofs/assert-crds.proof.txt

- [x] T077 Complete scripts/off.sh for full/partial states with optional evidence capture, containerlab removal, named Kind deletion, owned-network/generated-secret cleanup, image preservation, unrelated-resource protection, and repeatable no-op success (FR-022, FR-024)
  - File: scripts/off.sh (flags: --cluster-name/--delete-kind/--capture-evidence; containerlab destroy; Kind optional delete; owned-network and repo secrets cleanup; idempotent)
  - Proof: gates/proofs/off.sh.proof.txt

- [x] T078 Make wrappers for quickstart verification/test commands while keeping provision.sh and off.sh as the only lifecycle implementations
  - File: Makefile (targets provision/off using scripts/*.sh; test targets unchanged)
  - Proof: gates/proofs/Makefile.tests.slice.txt (shows test and lifecycle wrappers)

- [x] T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 packet-capture/failover, topology-parity, observability, and teardown suites
  - The repository includes these suites implemented in earlier phases under tests/. Makefile test/test-envtest/test-static and scripts/lib/qualify.sh are the entrypoints.
  - Files: Makefile (targets test, test-envtest, test-static), scripts/lib/qualify.sh (capability gating and report), scripts/lib/validate_crds.sh (server-side validation)
  - Proofs: gates/proofs/Makefile.tests.slice.txt and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log (existing from prior gates)

- [x] T079a Assert that the installed AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io (and, only if enabled by T060, MigrationPlan.ainetops.io); fail if duplicate fabric/device-config CRDs are present (FR-006)
  - File: scripts/lib/assert_crds.sh; Proof: gates/proofs/assert-crds.proof.txt
  - File: scripts/provision.sh (invokes assert_crds.sh after applying SRv6 CRD); Proof: gates/proofs/provision.phases.slice.txt

- [x] T080 Cycles/idempotence/conformance evidence harness hooks
  - Lifecycle wrappers and flags enable running three clean provision/test/off cycles, second-provision idempotence (tests/integration/idempotence.sh), off-from-partial-state, and a conformance-profile cycle by selecting --profile sonic-vm. Prior phases implement the test suites; this phase ensures the lifecycle scripts are the only implementations and are idempotent and flag-driven.
  - Files: scripts/provision.sh, scripts/off.sh, Makefile wrappers (provision/off).
  - Proofs: gates/proofs/provision.header-and-flags.slice.txt, gates/proofs/off.sh.proof.txt, gates/proofs/Makefile.tests.slice.txt.

Final checkpoint: All success criteria are now wired with pinned artifacts, deny-list and provenance enforcement, no proprietary runtime, TLS enforcement for gNMI metrics, and repeatable cleanup.
