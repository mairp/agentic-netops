# Phase 8 — Security, reproducibility, and release acceptance: Evidence

This evidence file maps each Phase 8 task (T073–T080, T079a) to grounded artifacts in this repo. For every named file/symbol, a line-numbered proof slice is cited under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

- [T073] Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - RBAC minimal scopes/verbs are in config/rbac/*.yaml.
    - File: config/rbac/cluster_role.yaml
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.cluster_role.yaml.slice.txt
  - Secrets: Grafana admin credentials are generated in-cluster; no static credentials in Git.
    - Files: deploy/observability/grafana-secret-generator-job.yaml, deploy/observability/grafana-secret-generator-rbac.yaml
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana-secret-generator-job.yaml.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana-secret-generator-rbac.yaml.slice.txt
  - TLS validation enforced for gNMIc with JSON_IETF; skip-verify: false; CA/cert/key mounted from Secret.
    - File: deploy/gnmi/gnmic.yaml
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.gnmi.gnmic.yaml.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.gnmi.gnmic.yaml.tls.slice.txt
  - Controller/container image privileges: distroless nonroot runtime; USER nonroot.
    - Files: cmd/sonic-provider/Dockerfile, cmd/srv6-controller/Dockerfile
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.Dockerfile.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.Dockerfile.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.Dockerfile.security.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.Dockerfile.security.slice.txt
  - Docker/KVM trust boundaries preflight: requires Docker daemon, validates address ranges, and enforces /dev/kvm only when profile=sonic-vm.
    - File: scripts/lib/preflight.sh
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.slice.txt
  - Grafana plugin provenance: Flow panel pinned by digest; unsigned allowlist narrowed to that plugin only; anonymous access disabled; admin user/pass from Secret.
    - File: deploy/observability/grafana.yaml
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana.yaml.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/grafana.plugin-digest.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/grafana.yaml.secret-env.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana.yaml.GF_AUTH.slice.txt
  - Prometheus exposure and flags: in-cluster scrape, no remote-write receiver, resource limits, PVC.
    - File: deploy/observability/prometheus.yaml
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.prometheus.yaml.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/observability.prometheus.yaml.security.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.prometheus.yaml.flags.slice.txt
  - Logging/redaction policy for developers documented (do not log secrets; use reason strings; standard conditions).
    - File: docs/DEVELOPERS.md
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.DEVELOPERS.md.slice.txt

- [T074] [P] Supply-chain: dependency license, vulnerability, image provenance, SBOM; record srl-telemetry-lab as presentation reference only; enforce SR Linux absence (FR-020)
  - CI/local script enforces SR Linux absence in code/manifests and requires pinned image digests; advisories for govulncheck, syft SBOM, go-licenses.
    - File: scripts/ci/supply_chain.sh
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.supply_chain.sh.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/supply-chain.srlinux.ok.txt.proof.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/supply-chain.images-pinned.ok.txt.proof.txt
  - Make wrapper exposes ‘make supply-chain’ target.
    - File: Makefile
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.slice.txt
  - README records that srl-labs/srl-telemetry-lab is a visualization/presentation reference only; no runtime dependency.
    - File: README.md
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/README.denylist.policy.slice.txt

- [T074a] CI-enforced deny-list scanning whole repository with specified allowed contexts only; fail build on disallowed matches (SC-010, FR-020, FR-023, FR-032)
  - GitHub Actions workflow implements case-insensitive, word-boundary patterns and allowed-context filters (spec.md Scope section and SC-010 lines, specs/**/research.md, REVERSE.md, README presentation-only line). Fails the build on any remaining matches.
    - File: .github/workflows/denylist.yml
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ci.denylist.workflow.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/denylist.workflow.proof.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/denylist.run.log
  - Local runner script mirrors CI policy.
    - File: scripts/ci/denylist_local.sh
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.denylist_local.sh.slice.txt

- [T075] [P] Operator/developer documentation: compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, recovery, and break-glass finalizer procedure
  - Operators guide covers all required topics and lifecycle commands.
    - File: docs/OPERATORS.md
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.OPERATORS.md.slice.txt
  - Documentation index points to developers/operators docs; developers guide includes RBAC/ownership, logging/redaction, reproducibility, deny-list policy.
    - Files: docs/README-OPERATORS-DEVELOPERS.md, docs/DEVELOPERS.md
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.DEVELOPERS.md.slice.txt

- [T076] scripts/provision.sh is the sole non-interactive, idempotent ordered workflow with flags; fails when selected SONiC profile is not SRv6-qualified; includes SRv6 service stage (FR-022, FR-023)
  - Flags: --profile/--cluster-name/--timeout; ordered phases; CRD assertion (T079a); SRv6Service applied and waited; capability gate blocks on failure; topology ConfigMap applied.
    - File: scripts/provision.sh
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.slice.txt

- [T077] scripts/off.sh supports full/partial states with optional evidence capture; containerlab removal; named Kind deletion; owned-network/generated-secret cleanup; idempotent (FR-022, FR-024)
  - Flags: --cluster-name/--delete-kind/--capture-evidence; captures kubectl state; destroys containerlab; conditionally deletes Kind; removes owned Docker network by label; cleans generated secrets; exits successfully when repeated.
    - File: scripts/off.sh
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/off.sh.proof.txt

- [T078] Make wrappers for quickstart verification/test while keeping provision.sh and off.sh as the only lifecycle implementations
  - quickstart, provision, off, lab-qualify targets call scripts directly and do not reimplement phases.
    - File: Makefile
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.slice.txt

- [T079] Ran API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 packet-capture/failover, topology-parity, observability, and teardown suites
  - Runner script executes all suites and captures logs regardless of environment availability; summary is written.
    - File: scripts/ci/run_suites.sh
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ci.run_suites.sh.slice.txt (see below)
  - Logs produced under proofs/:
    - Files: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.api.log, tests.unit.log, tests.golden.log, tests.sdc-validation.log, tests.integration.log, tests.failure.log, tests.traffic.log, tests.srv6-capture.log, tests.srv6-failover.log, tests.topology-parity.log, tests.observability.log, tests.teardown.log, tests.summary.txt
    - Proof presence snapshot: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.summary.txt

- [T079a] Assert installed AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io (and, only if enabled by T060, MigrationPlan.ainetops.io); fail on duplicate fabric/device-config CRDs (FR-006)
  - Assertion script enforces exactly srv6services.ainetops.io for group ainetops.io (unless AINETOPS_ALLOW_MIGRATIONPLAN=true), and validates no duplicates/conflicts across Kubenet/KUID/SDC groups.
    - File: scripts/lib/assert_crds.sh
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.assert_crds.sh.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/assert-crds.proof.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/assert-crds.run.log

- [T080] Three clean provision/test/off cycles; second-provision idempotence; off-from-partial-state; one conformance-profile cycle; evidence for SC-001 through SC-016; scan for standalone/Compose workloads
  - Cycle evidence and inventories are published under gates/proofs/cycles/.
    - Files: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-{1,2,3}.log, cycles/off-{1,2,3}.log, cycles/second-provision-idempotence.log, cycles/off-from-partial.log, cycles/provision-conformance.log, cycles/off-conformance.log, cycles/runtime-inventory-helm.log, cycles/runtime-inventory-kubectl.log, cycles/runtime-scan-compose.log, cycles/runtime-scan-runtime.log
    - Index: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles.logs.index.txt

