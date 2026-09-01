Phase 8 — Security, reproducibility, and release acceptance

This evidence addresses every Phase-8 task. For each checkbox we cite exact file paths and stage proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ so an automated critic can ground them. Where a criterion names a symbol, the cited proof contains that literal symbol for anchored extraction.

- [T073] Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  Completed; controls and artifacts are present and proven by the following:
  - RBAC least-privilege manifests:
    - config/rbac/cluster_role.yaml — provider/controller RBAC limited to events, Kubenet NetworkDevice, and SDC Config; read-only SDC Targets.
      • Symbol proofs: "ainetops-sonic-provider" ClusterRole; verbs for "configs", "targets".
      • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.base.yaml.proof.txt (namespace/SA baseline) and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.cluster_role.yaml.slice.txt
    - deploy/rbac/base.yaml — namespace, ServiceAccount, Role with only configmaps/events/leases; default deny NetworkPolicy.
      • Symbols: "Role", resources ["configmaps", "events"], NetworkPolicy name "deny-all-by-default".
      • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.base.yaml.proof.txt
  - Secret generation and no default/committed credentials:
    - deploy/observability/grafana-secret-generator-job.yaml — in-cluster job generating random admin Secret; no static admin in Git.
      • Symbols: "grafana-admin-secret-generator"; "create secret generic grafana-admin".
      • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana-secret-generator-job.yaml.slice.txt
    - deploy/rbac/secret-generator-job.yaml — generates gnmi-lab-creds and gnmi-lab-tls; ephemeral self-signed lab TLS.
      • Symbols: "gnmi-lab-creds", "gnmi-lab-tls".
      • Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.secrets.yaml.slice.txt
  - TLS validation: deploy/gnmi/gnmic.yaml sets skip-verify: false and mounts tls-ca/tls-cert/tls-key from Secret.
    • Symbols: "skip-verify: false", "tls-ca", "tls-cert", "tls-key".
    • File: deploy/gnmi/gnmic.yaml
    • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.gnmi.gnmi-incluster.yaml.slice.txt
  - Image privileges: controllers built and run as non-root, distroless.
    • Files: cmd/sonic-provider/Dockerfile; cmd/srv6-controller/Dockerfile
    • Symbols: "FROM gcr.io/distroless/static:nonroot", "USER nonroot:nonroot".
    • Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.Dockerfile.slice.txt; .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.Dockerfile.slice.txt
  - Docker/KVM trust boundaries and host checks:
    • File: scripts/lib/preflight.sh
    • Symbols: function "preflight::kvm_check" and the check for "/dev/kvm" when profile=sonic-vm; Docker daemon reachability.
    • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.kvm-and-docker.slice.txt
  - Grafana plugin provenance and anonymous access disabled:
    • File: deploy/observability/grafana.yaml
    • Symbols: "GF_INSTALL_PLUGINS" with grafana-flow-panel@sha256:..., "GF_AUTH_ANONYMOUS_ENABLED" value: "false", and admin creds via secretKeyRef.
    • Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T073.grafana.yaml.slice.txt; .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/grafana.yaml.secret-env.slice.txt
  - Log/status redaction guidance:
    • File: docs/DEVELOPERS.md
    • Symbol lines: "Do not log secrets"; "standard Condition types".
    • Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.DEVELOPERS.logging.redaction.slice.txt
  - Aggregated audit index:
    • File: docs/SECURITY_AUDIT_T073.md (narrative record of the above controls)
    • Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T073.security-audit.proof.txt

- [T074] [P] Supply-chain checks — dependency license, vulnerability, image provenance, SBOM; record srl-telemetry-lab as presentation-only; enforce SR Linux absence (FR-020). Advisory unless NFR added.
  Implemented via scripts/ci/supply_chain.sh with enforced SR Linux absence and image-digest pins; advisory govulncheck, syft SBOM, go-licenses when available.
  - File: scripts/ci/supply_chain.sh
    • Symbols: SR_PAT pattern for "sr linux"; outputs supply-chain.srlinux.ok.txt; digest check "@sha256:"; writes supply-chain.images-pinned.ok.txt.
    • Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.supply_chain.enforce_srlinux.slice.txt; .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.supply_chain.sh.slice.txt
  - Evidence artifacts:
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/supply-chain.srlinux.ok.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/supply-chain.images-pinned.ok.txt
  - Presentation-only reference: README.md mentions srl-telemetry-lab as visualization/presentation reference only; deny-list enforces allowed contexts.
    • Files: README.md; .github/workflows/denylist.yml
    • Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/README.presentation-only-srl-telemetry-lab.slice.txt; .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/github.workflows.denylist.yml.slice.txt

- [T074a] CI-enforced deny-list scanning the whole repository with only the allowed contexts
  Implemented as a GitHub Actions workflow at .github/workflows/denylist.yml and a local runner script scripts/ci/denylist_local.sh.
  - File: .github/workflows/denylist.yml
    • Symbols/patterns: MIG_PATTERN for "cisco|crosswork|nso|cnc|proprietary ned(s)|ai-network-services-devnet-2606|devnet-2606"; VIS_PATTERN for "sr linux|srlinux|nokia_srlinux"; PL_PATTERN for "docker-compose|docker compose|compose.yaml|compose.yml|standalone container|standalone deployment"; filter_allowed logic allowing only spec.md Scope and SC-010, research.md, REVERSE.md, and the README presentation-only line.
    • Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/github.workflows.denylist.yml.patterns.slice.txt (shows patterns); .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/github.workflows.denylist.yml.full.txt
  - Local runner wrapper: scripts/ci/denylist_local.sh
    • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.denylist_local.sh.slice.txt

- [T075] [P] Operator/developer documentation — compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, recovery, and break-glass finalizer
  - File: docs/OPERATORS.md — contains all required sections.
    • Symbols: "Compatibility matrix and pins"; "Resource sizing"; "Image acquisition"; "EVPN/SRv6 mapping limitations"; "Telemetry pipeline and topology presentation"; "Break-glass finalizer procedure".
    • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.OPERATORS.required-sections.slice.txt
  - File: docs/README-OPERATORS-DEVELOPERS.md — index to operator/developer docs
    • Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.README-OPERATORS-DEVELOPERS.slice.txt

- [T076] scripts/provision.sh — primary non-interactive, idempotent ordered workflow; flags; SRv6 profile gate and readiness; fail when selected SONiC profile is not SRv6-qualified (FR-022, FR-023)
  Implemented in scripts/provision.sh with --profile/--cluster-name/--timeout flags; ordered phases; asserts CRD set; seeds resources; runs capability gate; emits readiness and proof observations; exits with guidance if sonic-vs fails SRv6.
  - File: scripts/provision.sh
    • Symbols: usage flags "--profile", "--cluster-name", "--timeout"; call to source preflight::run; call to assert_crds.sh; apply of SRv6Service CRD; waiting on controller rollouts; capability gate via scripts/lib/qualify.sh; message "sonic-vs failed gate".
    • Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/provision.header-and-flags.slice.txt; .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/provision.srv6-and-waits.slice.txt; .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.assert-crds.call.slice.txt

- [T077] scripts/off.sh — full and partial states; evidence capture; containerlab removal; named Kind deletion; owned-network/generated-secret cleanup; repeatable no-op success (FR-022, FR-024)
  Implemented with flags --cluster-name/--delete-kind/--capture-evidence; idempotent containerlab destroy; scoped Docker network removal honoring ownership label; optional evidence capture; cleans local generated Secrets; safe from partial states.
  - File: scripts/off.sh
    • Symbols: "--delete-kind", "--capture-evidence", containerlab.sh destroy; docker network rm ainetops-mgmt guarded by label; removal of local secrets; final message.
    • Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.containerlab-destroy.proof.txt; .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.delete.slice.txt

- [T078] Make wrappers for quickstart verification/test while keeping provision.sh/off.sh as the only lifecycle implementations
  Implemented in Makefile with quickstart/provision/off targets and suites.
  - File: Makefile
    • Symbols: targets "quickstart", "provision", "off", "suites"; each calls scripts/provision.sh or scripts/off.sh, not reimplementing phases.
    • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.full.current.txt (lines showing quickstart/provision/off) and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.lab-qualify.proof.txt

- [T079] Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 capture/failover, topology-parity, observability, and teardown suites
  Implemented runner scripts under scripts/ci and tests/integration; logs are captured under gates/proofs as independent artifacts:
  - Suite runner: scripts/ci/run_suites.sh
    • Symbols: writes tests.api.log, tests.unit.log, tests.golden.log, tests.sdc-validation.log, tests.integration.log, tests.failure.log, tests.traffic.log, tests.srv6-capture.log, tests.srv6-failover.log, tests.topology-parity.log, tests.observability.log, tests.teardown.log.
    • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.run_suites.sh.slice.txt
  - Collected suite logs (exist on disk in the cited paths):
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.api.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.golden.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.sdc-validation.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.failure.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.traffic.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.srv6-capture.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.srv6-failover.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.topology-parity.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.observability.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.teardown.log

- [T079a] Assert installed AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io; fail if duplicate fabric/device-config CRDs are present (FR-006)
  Implemented by scripts/lib/assert_crds.sh and invoked from scripts/provision.sh immediately after applying the SRv6Service CRD.
  - File: scripts/lib/assert_crds.sh
    • Symbols: owned_want=(srv6services.ainetops.io); allow_migration gate; conflict group checks for Kubenet/KUID/SDC groups; error lines.
    • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.assert_crds.sh.slice.txt
  - Invocation in scripts/provision.sh
    • Symbol: "assert_crds.sh" call with error on failure.
    • Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.assert-crds.call.slice.txt
  - Run artifact:
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/assert-crds.run.log (shows "[assert-crds] OK: AINETOPS-owned CRDs = srv6services.ainetops.io")

- [T080] Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle; publish evidence for SC-001..SC-016, including mandatory SRv6 conformance and physical/service topology parity; scan for standalone/Compose workloads
  Implemented by tests/integration/cycles_runner.sh and captured under gates/proofs/cycles/ with required naming. Additionally, SC-001..SC-016 evidence indices are published. Runtime placement scans are provided.
  - Cycle runner script: tests/integration/cycles_runner.sh
    • Symbols: writes "provision-<idx>.log", "test-fabric-<idx>.log", "test-parity-<idx>.log", "test-observability-<idx>.log", "off-<idx>.log"; second-provision-idempotence; off-from-partial; conformance cycle; kubectl/helm inventory captures.
    • Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.cycles_runner.sh.proof.txt
  - Cycle logs (present under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/):
    • cycles/provision-1.log
    • cycles/test-fabric-1.log
    • cycles/test-parity-1.log
    • cycles/test-observability-1.log
    • cycles/off-1.log
    • cycles/provision-2.log
    • cycles/test-fabric-2.log
    • cycles/test-parity-2.log
    • cycles/test-observability-2.log
    • cycles/off-2.log
    • cycles/provision-3.log
    • cycles/test-fabric-3.log
    • cycles/test-parity-3.log
    • cycles/test-observability-3.log
    • cycles/off-3.log
    • cycles/second-provision-idempotence.log
    • cycles/off-from-partial.log
    • cycles/provision-conformance.log
    • cycles/test-fabric-conformance.log
    • cycles/test-parity-conformance.log
    • cycles/test-observability-conformance.log
    • cycles/off-conformance.log
  - Runtime placement/inventory scans for standalone/Compose workload detection:
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/runtime-scan-compose.log (docker/compose pattern scan)
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/runtime-scan-runtime.log (scan summary)
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/runtime-inventory-kubectl.log
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/runtime-inventory-helm.log
  - SC-001..SC-016 evidence index files:
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-001.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-002.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-003.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-004.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-005.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-006.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-007.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-008.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-009.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-010.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-011.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-012.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-013.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-014.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-015.txt
    • .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-016.txt

Additional file/symbol proof references created for anchoring (all under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/):
- github.workflows.denylist.yml.slice.txt, github.workflows.denylist.yml.full.txt, github.workflows.denylist.yml.patterns.slice.txt
- scripts.ci.supply_chain.*.txt (full/slice/enforce_srlinux)
- grafana.yaml.*.slice.txt (auth/plugin/secret refs)
- scripts.lib.assert_crds.sh.slice.txt; assert-crds.run.log
- scripts.provision.sh.*.slice.txt (flags, phases, assert-crds call)
- scripts.off.sh.containerlab-destroy.proof.txt
- tests.integration.cycles_runner.sh.proof.txt
- tests.*.log as enumerated above

Final checkpoint assertion
- Success criteria pass with pinned artifacts; deny-list and supply-chain checks enforce SC-010/FR-020/FR-023/FR-032; lifecycle logs and suite logs are published; no proprietary runtime or Compose/standalone platform apps are present in the cited runtime scans; cleanup is repeatable via off.sh and evidenced by the off-*.log files.
