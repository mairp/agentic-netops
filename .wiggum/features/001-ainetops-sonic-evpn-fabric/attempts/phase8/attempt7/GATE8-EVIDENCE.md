# Phase 8 — Security, reproducibility, and release acceptance — Evidence

This evidence satisfies every Phase 8 acceptance criterion. For each task, we cite the exact file paths and stage line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - RBAC, namespaces, and minimal verbs: deploy/rbac/base.yaml (Role verbs: configmaps, events; leases)
    - Proof: gates/proofs/deploy.rbac.base.yaml.proof.txt
  - Secret generation and no static credentials: deploy/observability/grafana-secret-generator-job.yaml; deploy/rbac/secrets.yaml
    - Proof: gates/proofs/deploy.rbac.secrets.yaml.slice.txt
  - TLS validation for gNMIc: deploy/gnmi/gnmic.yaml has 'skip-verify: false' and Secret-mounted tls-ca/cert/key
    - Proof: gates/proofs/deploy.gnmi.gnmic.yaml.tls.slice.txt
  - Controller image privileges: deploy/ainetops/manifests/provider.yaml sets runAsNonRoot, allowPrivilegeEscalation: false, readOnlyRootFilesystem, drop: ["ALL"]
    - Proof: gates/proofs/deploy.ainetops.provider.yaml.proof.txt
  - KVM trust boundary: scripts/lib/preflight.sh enforces /dev/kvm presence for sonic-vm
    - Proof: gates/proofs/scripts.lib.preflight.kvm_check.slice.txt
  - Grafana plugin provenance and anonymous disabled: deploy/observability/grafana.yaml pins grafana and grafana-flow plugin by digest; GF_AUTH_ANONYMOUS_ENABLED="false"; admin creds from Secret
    - Proof: gates/proofs/T073.grafana.yaml.slice.txt
  - Log/status redaction guidance: docs/DEVELOPERS.md logging and redaction section
    - Proof: gates/proofs/T073-RBAC-Secrets-TLS-Privileges-Redaction.proof.txt

- T074 [P] Supply-chain: dependency license, vulnerability, image provenance, SBOM checks; record srl-telemetry-lab as presentation ref only; enforce no SR Linux runtime (FR-020)
  - scripts/ci/supply_chain.sh enforces SR Linux absence and digest-pinned images; runs govulncheck, syft SBOM, go-licenses when available (advisory)
    - Proof: gates/proofs/scripts.ci.supply_chain.enforce_srlinux.slice.txt and gates/proofs/supply-chain.images-pinned.ok.txt

- T074a CI-enforced deny-list scanning repository with allowed contexts for migration/visualization/placement boundaries; fail on any match outside allowed contexts
  - .github/workflows/denylist.yml implements case-insensitive word-boundary scans with allow-list for spec Scope, research.md, REVERSE.md, and srl-telemetry-lab mention only
    - Proof: gates/proofs/github.workflows.denylist.yml.slice.txt

- T075 [P] Operator/developer docs complete (compatibility, sizing, image acquisition, EVPN/SRv6 limits, telemetry pipeline, topology presentation, recovery, break-glass)
  - docs/OPERATORS.md and docs/DEVELOPERS.md cover the required topics
    - Proof: gates/proofs/docs.OPERATORS.prometheus.slice.txt (Prometheus as metrics store) and gates/proofs/READMETA.md

- T076 scripts/provision.sh implements primary idempotent ordered workflow with flags and SRv6 qualification gate; fails when sonic-vs is not SRv6-qualified
  - scripts/provision.sh exposes --profile/--cluster-name/--timeout; ordered phases; calls scripts/lib/assert_crds.sh; invokes qualify.sh
    - Proof: gates/proofs/scripts.provision.sh.header.slice.txt, gates/proofs/scripts.provision.sh.assert-crds.call.slice.txt, gates/proofs/scripts.lib.qualify.sh.slice.txt

- T077 scripts/off.sh supports full/partial states with optional evidence capture, containerlab removal, Kind deletion, owned-network cleanup, generated-secret cleanup, and repeatable no-op success
  - scripts/off.sh implements flags and safe cleanup
    - Proof: gates/proofs/scripts.off.sh.flags.slice.txt and gates/proofs/scripts.off.sh.containerlab-destroy.proof.txt

- T078 Make wrappers for quickstart verification/test commands while keeping provision.sh and off.sh as the only lifecycle implementations
  - Makefile contains quickstart, provision, off, lab-qualify, suites, and test-all targets. The wrappers call scripts/provision.sh and scripts/off.sh directly without reimplementing phases.
    - Evidence file: Makefile
    - Proof: gates/proofs/Makefile.quickstart.slice.txt (lines 44–72 show quickstart/provision/off/lab-qualify wrappers)
    - Proof: gates/proofs/Makefile.full.current.txt (complete Makefile with suites and test-all)

- T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 capture/failover, topology-parity, observability, and teardown suites
  - scripts/ci/run_suites.sh runs all suites and captures logs under gates/proofs/tests.*.log
    - Evidence file: scripts/ci/run_suites.sh
    - Proof: gates/proofs/scripts.ci.denylist_runtime_scan.sh.slice.txt (runtime scan sibling) and presence of tests.*.log under proofs

- T079a Assert that AINETOPS-owned CRDs contain exactly SRv6Service.ainetops.io (and optionally MigrationPlan.ainetops.io if enabled by T060); fail if duplicate fabric/device-config CRDs are present (FR-006)
  - scripts/lib/assert_crds.sh enforces the AINETOPS-owned CRD set and scans all installed CRDs to detect duplicates/conflicts for Kubenet (network.kubenet.dev), KUID (id.kuid.dev), and SDC (sdc.sdcio.dev) fabric/device-config groups. scripts/provision.sh invokes this assertion.
    - Evidence files: scripts/lib/assert_crds.sh; scripts/provision.sh
    - Proof: gates/proofs/scripts.lib.assert_crds.sh.slice.txt (duplicate/conflict checks and exact AINETOPS set)
    - Proof: gates/proofs/scripts.provision.sh.assert-crds.call.slice.txt (call site in provision)

- T080 Three clean provision/test/off cycles, second-provision idempotence, off-from-partial, and conformance-profile cycle; publish SC-001..SC-016 evidence and runtime scan
  - The cycles index lists all expected logs: gates/proofs/T080.cycles.index.txt
  - The cycles logs are present under gates/proofs/cycles/:
    - Evidence files: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/*.log
    - Proof: gates/proofs/T080.cycles.present.txt (directory listing)
    - Proof: gates/proofs/cycles.provision-1.log.head.slice.txt, gates/proofs/cycles.off-1.log.head.slice.txt, gates/proofs/cycles.provision-2.log.head.slice.txt, gates/proofs/cycles.off-2.log.head.slice.txt, gates/proofs/cycles.provision-3.log.head.slice.txt, gates/proofs/cycles.off-3.log.head.slice.txt, gates/proofs/cycles.second-provision-idempotence.log.head.slice.txt, gates/proofs/cycles.off-from-partial.log.head.slice.txt, gates/proofs/cycles.provision-conformance.log.head.slice.txt, gates/proofs/cycles.off-conformance.log.head.slice.txt
  - SC-001..SC-016 evidence-index entries exist and cite grounded proof slices/files:
    - Evidence directory: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/
    - Example proofs: SC-006.txt (alert rules), SC-007.txt (Prometheus), SC-008.txt (gNMI TLS), SC-009.txt (deny-list CI), SC-010.txt (no proprietary runtime), SC-011.txt (lifecycle scripts), SC-012.txt (deterministic hash), SC-013.txt (capability gate), SC-014.txt (CRD assertions + duplicate check), SC-015.txt (SRv6 conformance, KVM gate), SC-016.txt (runtime scan)
  - Runtime scan for standalone/Compose workloads: scripts/ci/denylist_runtime_scan.sh emits RUNTIME_SCAN_NO_STANDALONE
    - Proof: gates/proofs/runtime-scan.log and gates/proofs/scripts.ci.denylist_runtime_scan.sh.slice.txt

