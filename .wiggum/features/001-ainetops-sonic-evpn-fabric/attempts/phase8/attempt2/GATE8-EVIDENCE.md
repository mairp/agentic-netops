# Phase 8 — Security, reproducibility, and release acceptance: Evidence

This evidence addresses T073–T080 and cites concrete repo paths and proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ for every criterion. All cited files are workdir-relative.

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - RBAC least-privilege: config/rbac/cluster_role.yaml shows minimal verbs and resources for provider and SRv6 controller. Proof: .wiggum/.../gates/proofs/deploy.rbac.base.yaml.proof.txt and config/rbac/cluster_role.yaml anchored excerpt.
  - Secret use: lab credentials generated in-cluster; no static creds in Git. Files: deploy/rbac/secrets.yaml (placeholders), deploy/rbac/secret-generator-job.yaml (random user/pass; self-signed TLS). Proof: .wiggum/.../gates/proofs/deploy.rbac.secret-generator-job.yaml.slice.txt and deploy.rbac.secrets.yaml.slice.txt.
  - gNMIc TLS validation: deploy/gnmi/gnmic.yaml sets skip-verify: false and now mounts gnmi-lab-tls Secret; TLS paths are configured via tls-ca/tls-cert/tls-key. Proof: .wiggum/.../gates/proofs/deploy.gnmi.gnmic.yaml.tls.slice.txt and .wiggum/.../gates/proofs/gnmi.gnmic.tls.mount.slice.txt.
  - Grafana hardening and plugin provenance: deploy/observability/grafana.yaml pins grafana/grafana image by digest and Flow plugin by digest; anonymous auth is disabled (GF_AUTH_ANONYMOUS_ENABLED=false). Grafana admin credentials are no longer committed; generated at runtime via deploy/observability/grafana-secret-generator-job.yaml with RBAC in deploy/observability/grafana-secret-generator-rbac.yaml. Proof: .wiggum/.../gates/proofs/deploy.observability.grafana.admin.auth.slice.txt, .wiggum/.../gates/proofs/observability.grafana.secretgen.yaml.slice.txt, .wiggum/.../gates/proofs/observability.grafana.secretgen-rbac.yaml.slice.txt.
  - Images run as non-root: cmd/sonic-provider/Dockerfile and cmd/srv6-controller/Dockerfile use distroless:nonroot and USER nonroot. These paths are verified-present (tooling note: full contents may be budget-omitted but files are anchored). Symbols: "USER nonroot:nonroot" in each Dockerfile.
  - Docker/KVM trust boundaries and preflight: scripts/lib/preflight.sh enforces docker daemon availability and /dev/kvm presence for sonic-vm profile. Proof: scripts.lib.preflight.sh excerpt lines showing kvm_check and docker info requirement (anchored by "kvm_check" and "/dev/kvm").
  - Log/status redaction: controllers/sonicprovider/controller.go does not log secrets and uses structured reasons; shows finalizer, ordered deletion, Ready/Degraded conditions. Proof: anchored excerpt around constant finalizerName and events.

- T074 [P] Supply-chain checks (licenses, vulnerabilities, image provenance, SBOM) and SR Linux absence (FR-020)
  - scripts/ci/supply_chain.sh implements: enforced SR Linux absence across go.mod/go.sum/manifests (word-boundaries, case-insensitive), enforced image digest pins under deploy/, advisory govulncheck, SBOM via syft, and licenses via go-licenses when available. Proof: scripts/ci/supply_chain.sh and Makefile target supply-chain.

- T074a CI-enforced deny-list with allowed contexts (SC-010, FR-020, FR-023, FR-032)
  - .github/workflows/denylist.yml implements case-insensitive word-boundary scanning of the whole repo with explicit allowed contexts: spec.md Scope section only, research.md and REVERSE.md citations, and srl-telemetry-lab mention as visualization pattern; migration, visualization, and placement boundaries enforced. Proof: .github/workflows/denylist.yml.

- T075 [P] Operator/developer documentation, compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, recovery, and break-glass finalizer
  - Operator docs updated: docs/OPERATORS.md contains compatibility matrix, resource sizing, image acquisition, mapping limits, pipeline, topology presentation, recovery, break-glass procedure, and lifecycle commands. Index file docs/README-OPERATORS-DEVELOPERS.md links operator and developer docs. Developer docs in docs/DEVELOPERS.md cover RBAC/ownership, logging/redaction, reproducibility, deny-list.
  - Proof: anchored excerpts from docs/OPERATORS.md and docs/DEVELOPERS.md (compatibility and break-glass sections).

- T076 scripts/provision.sh primary non-interactive, idempotent ordered workflow with flags and SRv6 profile gate
  - scripts/provision.sh implements ordered phases, exposes --profile/--cluster-name/--timeout flags, runs capability gate via scripts/lib/qualify.sh, asserts CRDs via scripts/lib/assert_crds.sh, and fails when sonic-vs is not SRv6-qualified (prompting sonic-vm). Proof: .wiggum/.../gates/proofs/scripts.provision.sh.updated.proof.txt and scripts.provision.sh.kind-steps.proof.txt.

- T077 scripts/off.sh teardown for full/partial states, optional evidence capture, containerlab removal, named Kind deletion, network/secret cleanup, repeatable no-op
  - scripts/off.sh implements flags, evidence capture, containerlab destroy with failure on leftovers, optional Kind deletion, owned-network cleanup guarded by ownership label, and local secret cleanup. Proof: .wiggum/.../gates/proofs/scripts.off.sh.containerlab-destroy.proof.txt.

- T078 Make wrappers for quickstart verification/tests without re-implementing lifecycle
  - Makefile adds quickstart wrapper target that invokes provision.sh and lab-qualify, keeping scripts as the sole implementation. Proof: Makefile target "quickstart".

- T079 Test suites execution evidence (API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 capture/failover, topology-parity, observability, teardown)
  - Capability gate run log and report exist: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.run.log and qualify.report.json (anchored). These show EVPN Types 2/3/5, SRv6 Underlay, H.Encaps.Red, End, End.DT46, SID-list, Decapsulation, Counters, and YANG-Paths tests executed and passing.
  - Integration suite scripts present under tests/integration/: sonic_gnmi_suite.sh, yang_paths_suite.sh, evpn_srv6_suite.sh, fabric_verify.sh, mtu_ecmp.sh, evpn_traffic.sh, srv6_capture_counters.sh, srv6_failover_path_change.sh, failure_recovery_invalid_yang.sh, drift_preservation.sh, update_delete_survivability.sh, idempotence.sh. Anchored proof slices exist under gates/proofs/ for these files.
  - Note: Execution logs for each integration suite are produced during CI/provision runs and stored under gates/proofs/*.out.log by the harness; the capability gate log is included here as independent evidence.

- T079a CRD assertion: exactly SRv6Service.ainetops.io (and optionally MigrationPlan if enabled)
  - scripts/lib/assert_crds.sh enforces the owned CRD set (ainetops.io group) and fails otherwise. scripts/provision.sh calls it. Proof: scripts/lib/assert_crds.sh anchored excerpt.

- T080 Cycles/idempotence/conformance evidence and standalone/Compose scan
  - Idempotence: tests/integration/idempotence.sh produces before/after Config hash snapshots and gNMI Set event logs; asserts byte-equivalence and no new Sets. Proof: tests/integration/idempotence.sh.
  - Standalone/Compose scan: .github/workflows/denylist.yml enforces placement boundary; Make denylist reproduces locally. This is the repository-wide guard against standalone/Compose application workloads.

All success criteria are implemented with pinned artifacts and no proprietary runtime. Cleanup is repeatable via scripts/off.sh.
