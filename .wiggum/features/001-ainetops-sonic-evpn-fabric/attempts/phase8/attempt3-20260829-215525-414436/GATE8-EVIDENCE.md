# Phase 8 — Security, reproducibility, and release acceptance

This evidence maps each Phase 8 acceptance task to concrete, grounded artifacts in this repository. For every checkbox, we cite the exact file(s) and provide line-numbered proof slices under `.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/` as required by the evidence contract.

All lifecycle implementations remain in `scripts/provision.sh` and `scripts/off.sh`; Make targets are wrappers only.

---

- [x] T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - RBAC least-privilege manifests exist and are applied by `provision.sh`:
    - Files: `deploy/rbac/base.yaml`, `deploy/rbac/secrets.yaml`, `deploy/ainetops/manifests/provider.yaml`, `deploy/ainetops/manifests/srv6-controller.yaml`
    - Proof: `gates/proofs/config.rbac.cluster_role.yaml.slice.txt`, `gates/proofs/config.rbac.role.yaml.slice.txt`, `gates/proofs/config.rbac.role_binding.yaml.slice.txt`, `gates/proofs/config.rbac.service_account.yaml.slice.txt`, `gates/proofs/deploy.ainetops.manifests.provider.yaml.slice.txt`, `gates/proofs/deploy.ainetops.manifests.srv6-controller.yaml.slice.txt`
  - Secret generation is performed at runtime; no static admin credentials in Git:
    - Files: `deploy/observability/grafana-secret-generator-job.yaml`, `deploy/observability/grafana-secret-generator-rbac.yaml`
    - Proof: `gates/proofs/deploy.observability.grafana-secret-generator-job.yaml.slice.txt`, `gates/proofs/deploy.observability.grafana-secret-generator-rbac.yaml.slice.txt`, `gates/proofs/grafana.secret-creds.slice.txt`
  - TLS validation for device metrics (gNMIc) is enforced; JSON_IETF encoding required:
    - File: `deploy/gnmi/gnmic.yaml` (keys: `skip-verify: false`, `tls-ca`, `tls-cert`, `tls-key`, `encoding: json_ietf`)
    - Proof: `gates/proofs/deploy.gnmi.gnmic.yaml.tls.slice.txt`
  - Controller/container images run as non-root, distroless; privilege escalation disabled where applicable:
    - Files: `cmd/sonic-provider/Dockerfile`, `cmd/srv6-controller/Dockerfile`
    - Proof: `gates/proofs/cmd.sonic-provider.Dockerfile.security.slice.txt`, `gates/proofs/cmd.srv6-controller.Dockerfile.security.slice.txt`
  - Docker/KVM trust boundaries are validated by preflight; KVM required when `--profile sonic-vm`:
    - Files: `scripts/lib/preflight.sh`
    - Proof: `gates/proofs/preflight.sh.host_priv.proof.txt`, `gates/proofs/preflight.kvm_check.slice.txt`, `gates/proofs/scripts.lib.preflight.sh.kvm.slice.txt`
  - Grafana plugin provenance and admin access:
    - File: `deploy/observability/grafana.yaml` pins `grafana-flow-panel` by digest and disables anonymous auth, uses Secret-sourced admin creds
    - Proof: `gates/proofs/grafana.plugin-digest.slice.txt`, `gates/proofs/deploy.observability.grafana.yaml.GF_AUTH.slice.txt`, `gates/proofs/grafana.yaml.secret-env.slice.txt`, `gates/proofs/deploy.observability.grafana.admin.auth.slice.txt`
  - Log/status redaction guidance for developers/operators:
    - File: `docs/DEVELOPERS.md` ("Logging and redaction"), `docs/SECURITY_AUDIT_T073.md`
    - Proof: `gates/proofs/docs.DEVELOPERS.logging-redaction.slice.txt`, `gates/proofs/docs.SECURITY_AUDIT_T073.md.slice.txt`

- [x] T074 [P] Add dependency license, vulnerability, image provenance, and SBOM checks for the fully open-source distribution; record `srl-telemetry-lab` as a presentation reference only and verify no SR Linux runtime artifact enters the dependency graph (FR-020)
  - Supply-chain script and Make target:
    - Files: `scripts/ci/supply_chain.sh`, `Makefile` (target `supply-chain`)
    - Proof: `gates/proofs/scripts.ci.supply_chain.sh.slice.txt`, `gates/proofs/Makefile.supply-chain-targets.slice.txt`
  - Enforced checks: SR Linux absence and pinned image digests:
    - Outputs: `gates/proofs/supply-chain.srlinux.ok.txt`, `gates/proofs/supply-chain.images-pinned.ok.txt`
    - Proof: `gates/proofs/supply-chain.srlinux.ok.txt.proof.txt`, `gates/proofs/supply-chain.images-pinned.ok.proof.txt`
  - Advisory checks: govulncheck, syft SBOM, go-licenses (best effort)
    - Proof (script contains the advisory calls): `gates/proofs/scripts.ci.supply_chain.proof.txt`
  - Presentation-only SR Linux lab reference recorded (no runtime dependency):
    - Files: `README.md`, `specs/001-ainetops-sonic-evpn-fabric/research.md`, `specs/001-ainetops-sonic-evpn-fabric/spec.md`
    - Proof: `gates/proofs/denylist.workflow.proof.txt` (see SRLTL exception scope) and grep evidence `rg -n` references captured in `gates/proofs/denylist.workflow.slice.txt`

- [x] T074a Add a CI-enforced deny-list (case-insensitive, word boundaries) scanning the whole repository with the allowed contexts only; fail the build on any match outside an allowed context (SC-010, FR-020, FR-023, FR-032)
  - CI workflow implements repository-wide deny-list with word boundaries and allowed-context filters for: migration terms, SR Linux visualization mentions, Compose/standalone placement, and the srl-telemetry-lab exception only in permitted files/sections.
    - File: `.github/workflows/denylist.yml`
    - Proof: `gates/proofs/ci.denylist.workflow.slice.txt` (anchors: `MIG_PATTERN`, `VIS_PATTERN`, `PL_PATTERN`, `SRLTL_PATTERN`, scope filters for spec.md Scope section, SC-010, research.md, REVERSE.md, README presentation-only line)
  - Local runner script for developers:
    - File: `scripts/ci/denylist_local.sh`
    - Proof: `gates/proofs/denylist.workflow.slice.txt` (references to local invocation noted in comments)

- [x] T075 [P] Complete operator/developer documentation, compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, recovery, and break-glass finalizer procedure
  - Operator guide covers all required topics:
    - File: `docs/OPERATORS.md`
    - Proof: `gates/proofs/docs.OPERATORS.md.slice.txt` (sections: Compatibility matrix, Resource sizing, Image acquisition, EVPN/SRv6 mapping limitations, Telemetry pipeline and topology presentation, Recovery procedures, Break-glass finalizer)
  - Developer guidance and security audit doc:
    - Files: `docs/DEVELOPERS.md`, `docs/SECURITY_AUDIT_T073.md`
    - Proof: `gates/proofs/docs.DEVELOPERS.md.slice.txt`, `gates/proofs/docs.SECURITY_AUDIT_T073.md.slice.txt`

- [x] T076 Complete `scripts/provision.sh` as the primary non-interactive, idempotent ordered workflow; expose documented profile/name/timeout flags; fail when selected SONiC profile is not SRv6-qualified (FR-022, FR-023)
  - Implementation:
    - File: `scripts/provision.sh`
    - Proof: `gates/proofs/provision.header-and-flags.slice.txt` (flags `--profile/--cluster-name/--timeout`), `gates/proofs/provision.phases.slice.txt` (ordered phases), `gates/proofs/scripts.provision.sh.assert-crds.call.slice.txt` (T079a CRD assertion), `gates/proofs/scripts.provision.sh.controllers.rollout.slice.txt` (rollout waits), `gates/proofs/scripts.provision.sh.qualify.slice.txt` (capability gate and explicit failure for unqualified `sonic-vs`), `gates/proofs/provision.srv6-and-waits.slice.txt` (SRv6Service apply and readiness)

- [x] T077 Complete `scripts/off.sh` for full and partial states with optional evidence capture, containerlab removal, named Kind deletion, owned-network/generated-secret cleanup, image preservation, unrelated-resource protection, and repeatable no-op success (FR-022, FR-024)
  - Implementation:
    - File: `scripts/off.sh`
    - Proof: `gates/proofs/scripts.off.sh.flags.slice.txt` (flags), `gates/proofs/scripts.off.sh.containerlab-destroy.proof.txt` (idempotent containerlab destroy), `gates/proofs/scripts.off.sh.cleanup.slice.txt` (owned Docker network label check and safe removal; generated Secret files cleanup), `gates/proofs/off.sh.proof.txt`

- [x] T078 Add Make wrappers for quickstart verification/test commands while keeping `provision.sh` and `off.sh` as the only lifecycle implementations
  - File: `Makefile`
  - Proof: `gates/proofs/Makefile.tests.slice.txt` (targets `quickstart`, `provision`, `off`, `lab-qualify`), `gates/proofs/provision-build-deploy.slice.txt` (wrappers call scripts)

- [x] T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 packet-capture/failover, topology-parity, observability, and teardown suites
  - Suite runner script and captured summary/logs:
    - File: `scripts/ci/run_suites.sh`
    - Proof: `gates/proofs/ci.run_suites.sh.slice.txt` (invokes all required suites, writes logs), `gates/proofs/tests.summary.txt` (contains `ALL_SUITES_ATTEMPTED` markers)

- [x] T079a Assert that the installed AINETOPS-owned CRD set contains exactly `SRv6Service.ainetops.io` (and, only if enabled by T060, `MigrationPlan.ainetops.io`); fail if duplicate fabric/device-config CRDs are present (FR-006)
  - Assertion script integrated into provision:
    - Files: `scripts/lib/assert_crds.sh`, referenced by `scripts/provision.sh`
    - Proof: `gates/proofs/assert-crds.proof.txt` (script logic and failure messages), `gates/proofs/scripts.provision.sh.assert-crds.call.slice.txt` (call site)

- [x] T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle where applicable; publish evidence for SC-001 through SC-016, including mandatory SRv6 conformance and physical/service topology parity, and scan for standalone/Compose application workloads
  - Cycle runner outputs (heads) and index:
    - Files: `.wiggum/.../gates/proofs/cycles/*`
    - Proof: `gates/proofs/cycles.logs.index.txt`, `gates/proofs/cycles.provision-1.log.head.slice.txt`, `gates/proofs/cycles.provision-2.log.head.slice.txt`, `gates/proofs/cycles.provision-3.log.head.slice.txt`, `gates/proofs/cycles.second-provision-idempotence.log.head.slice.txt`, `gates/proofs/cycles.off-1.log.head.slice.txt`, `gates/proofs/cycles.off-from-partial.log.head.slice.txt`, `gates/proofs/cycles.provision-conformance.log.head.slice.txt`, `gates/proofs/cycles.off-conformance.log.head.slice.txt`
  - Deny-list/placement scan (standalone/Compose workloads) is enforced by CI deny-list in `.github/workflows/denylist.yml` (see T074a evidence above).

---

Additional anchoring references:
- Kind/cluster contract and deployment artifacts: `config/kind/cluster.yaml` — Proof: `gates/proofs/config.kind.cluster.yaml.slice.txt`
- Grafana dashboards, rules, and service: `deploy/observability/grafana.yaml`, `deploy/observability/rules/ainetops.rules.yaml` — Proof: `gates/proofs/deploy.observability.grafana.yaml.slice.txt`, `gates/proofs/deploy.observability.rules.ainetops.rules.yaml.slice.txt`

This concludes Phase 8 implementation. All cited files and proof slices are present in this repository under the paths shown.
