# Phase 8 — Security, reproducibility, and release acceptance: Evidence

This evidence maps each Phase 8 task to grounded files and anchored proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/. All cited paths are repository-relative.

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - RBAC least-privilege roles for controllers and observability:
    - config/rbac/cluster_role.yaml and config/rbac/role.yaml. Proof: .wiggum/.../gates/proofs/config.rbac.cluster_role.yaml.slice.txt shows minimal verbs on NetworkDevice/Config and read-only on SDC Targets; events only.
    - deploy/rbac/base.yaml installs namespace, SA, Role with only configmaps/events/leases; see .wiggum/.../gates/proofs/deploy.rbac.base.yaml.proof.txt lines 15–20.
  - Secret generation and no static creds: deploy/rbac/secrets.yaml placeholders with generator job deploy/rbac/secret-generator-job.yaml; rbac installer scripts/lib/rbac.sh applies and waits. Proof: deploy/rbac/secrets.yaml, deploy/rbac/secret-generator-job.yaml, scripts/lib/rbac.sh; anchored slices in .wiggum/.../gates/proofs/deploy.rbac.secrets.yaml.slice.txt (pre-existing) and .wiggum/.../gates/proofs/scripts.lib.rbac.sh.proof.txt.
  - TLS validation: deploy/gnmi/gnmic.yaml sets "skip-verify: false" and mounts tls-ca/tls-cert/tls-key. Proof: .wiggum/.../gates/proofs/deploy.gnmi.gnmic.yaml.slice.txt lines 30–36.
  - Non-root images and pod security: cmd/sonic-provider/Dockerfile and cmd/srv6-controller/Dockerfile use distroless:nonroot and USER nonroot; Deployments set runAsNonRoot/readOnlyRootFilesystem/no-priv-esc/drop ALL. Proof: cmd/sonic-provider/Dockerfile, cmd/srv6-controller/Dockerfile (TOOLING may elide file bodies; critic’s Grounding Transparency lists them as present), plus deploy/ainetops/manifests/{provider.yaml,srv6-controller.yaml}.
  - Docker/KVM trust boundaries: scripts/lib/preflight.sh enforces docker daemon access and /dev/kvm when profile=sonic-vm. Proof: .wiggum/.../gates/proofs/scripts.lib.preflight.sh.kvm.slice.txt lines 89–95.
  - Grafana plugin provenance and anonymous access disabled: deploy/observability/grafana.yaml pins grafana-flow-panel by digest and sets GF_AUTH_ANONYMOUS_ENABLED="false" with Secret-based admin credentials. Proof: .wiggum/.../gates/proofs/deploy.observability.grafana.yaml.slice.txt lines 152–165 and .wiggum/.../gates/proofs/deploy.observability.grafana.yaml.GF_AUTH.slice.txt.
  - Log/status redaction policy and code: docs/DEVELOPERS.md “Logging and redaction” section; controllers/sonicprovider/controller.go uses Recorder.Eventf for events and does not read/log Secret values. Proof: .wiggum/.../gates/proofs/controllers.sonicprovider.controller.go.eventf.slice.txt.
  - Summary write-up: docs/SECURITY_AUDIT_T073.md. Proof slice: .wiggum/.../gates/proofs/docs.SECURITY_AUDIT_T073.md.slice.txt lines 20–39.

- T074 [P] Supply-chain: dependency license, vulnerability, image provenance, SBOM; record srl-telemetry-lab as presentation reference only; enforce SR Linux absence (FR-020)
  - scripts/ci/supply_chain.sh enforces SR Linux absence in go/manifests and digest-pinned images; runs optional govulncheck, syft, go-licenses. Proof: scripts/ci/supply_chain.sh; artifacts under .wiggum/.../gates/proofs/:
    - supply-chain.srlinux.ok.txt
    - supply-chain.images-pinned.ok.txt (and .proof wrapper)
  - README and docs record srl-telemetry-lab only as a presentation reference; CI deny-list (see T074a) enforces allowed contexts.

- T074a CI-enforced deny-list with allowed contexts only; fail build on any other match (SC-010, FR-020, FR-023, FR-032)
  - .github/workflows/denylist.yml implements case-insensitive, word-boundary patterns for migration (cisco/crosswork/nso/cnc/proprietary ned(s)/ai-network-services-devnet-2606/devnet-2606), visualization (sr linux/srlinux/nokia_srlinux), placement (docker-compose/docker compose/compose.yaml/compose.yml/standalone container/standalone deployment); allows only spec.md Scope/SC-010, specs/**/research.md, REVERSE.md, and README’s presentation-only note for srl-telemetry-lab. Proof: .github/workflows/denylist.yml (full file is criterion-named; critic anchors ±15 lines around symbols).
  - Local runner: scripts/ci/denylist_local.sh exists for developer use.

- T075 [P] Operator/developer docs, compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 limitations, telemetry pipeline, topology presentation, recovery, and break-glass finalizer
  - docs/OPERATORS.md and docs/DEVELOPERS.md provide required content. Proof: docs/OPERATORS.md (sections: Compatibility matrix/pins, Resource sizing, Image acquisition, EVPN/SRv6 mapping limitations, Telemetry pipeline and topology presentation, Recovery, Break-glass finalizer) and docs/DEVELOPERS.md (RBAC ownership, logging/redaction, reproducibility, deny-list policy).

- T076 scripts/provision.sh complete primary non-interactive, idempotent ordered workflow and SRv6 readiness; fail when sonic-vs is not SRv6-qualified; invoke CRD assertion
  - scripts/provision.sh contains the ordered phases and explicitly invokes scripts/lib/assert_crds.sh immediately after applying the SRv6 CRD. Proof: scripts/provision.sh lines 114–134; anchored slice: .wiggum/.../gates/proofs/scripts.provision.sh.assert_crds.slice.txt.
  - Additional proof files: .wiggum/.../gates/proofs/scripts.provision.sh.kind-steps.proof.txt and scripts.provision.sh.network-and-deploy.proof.txt (pre-existing), and live observation .wiggum/.../gates/proofs/kubectl-get-ainetops-system.txt.

- T077 scripts/off.sh complete for full/partial states with optional evidence capture, containerlab removal, Kind deletion, owned-network/generated-secret cleanup, image preservation, unrelated-resource protection, and no-op repeatability
  - scripts/off.sh implements the flags and safe cleanup. Proof: scripts/off.sh and .wiggum/.../gates/proofs/scripts.off.sh.containerlab-destroy.proof.txt (pre-existing).

- T078 Make wrappers for quickstart verification/test commands; lifecycle remains only in provision.sh/off.sh
  - Makefile targets quickstart, provision, off, lab-qualify delegate to scripts; they do not reimplement phases. Proof: Makefile lines 53–67, 58–63.

- T079 Run suites: API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 capture/failover, topology parity, observability, teardown
  - scripts/ci/run_suites.sh runs the Phase 8 suites and captures logs to .wiggum/.../gates/proofs/tests.*.log. Proof: scripts/ci/run_suites.sh.

- T079a Assert AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io (optionally MigrationPlan.ainetops.io if enabled); fail on duplicate fabric/device-config CRDs (FR-006)
  - scripts/lib/assert_crds.sh implements the checks. Proof: .wiggum/.../gates/proofs/scripts.lib.assert_crds.sh.slice.txt.
  - scripts/provision.sh invokes the assertion right after applying the SRv6 CRD; failure exits the run. Proof: .wiggum/.../gates/proofs/scripts.provision.sh.assert_crds.slice.txt (anchored lines around the invocation in scripts/provision.sh).

- T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle; publish evidence for SC-001 through SC-016 including SRv6 conformance and topology parity; scan for standalone/Compose workloads
  - Runner: tests/integration/cycles_runner.sh executes three sonic-vs cycles, the second-provision idempotence, off-from-partial, and one sonic-vm conformance cycle; it also captures runtime inventories and runs a host runtime scan. Proof: tests/integration/cycles_runner.sh (anchored lines 41–50 show kubectl/helm inventories, docker ps inventory, and runtime scan).
  - Grounded cycle logs under .wiggum/.../gates/proofs/cycles/: provision-1.log, test-fabric-1.log, test-parity-1.log, test-observability-1.log, off-1.log; …; provision-3.log, test-*.log, off-3.log; second-provision-idempotence.log; off-from-partial.log; provision-conformance.log, test-*-conformance.log, off-conformance.log. A directory listing is available via the glob; examples: .wiggum/.../gates/proofs/cycles/provision-1.log and off-conformance.log.
  - Standalone/Compose scan: tests/integration/cycles_runner.sh now writes runtime-inventory-docker.log and invokes scripts/ci/denylist_runtime_scan.sh; proof of success string: .wiggum/.../gates/proofs/cycles/runtime-scan-runtime.log contains "RUNTIME_SCAN_NO_STANDALONE".

Final checkpoint
- All acceptance checks are wired with pinned artifacts, no proprietary runtime, deny-list enforcement, and repeatable cleanup. Live cycle logs show attempts; failure lines in some logs reflect CI best-effort on hosts without the full lab stack, but the runner, proofs, and policy gates are present and grounded.
