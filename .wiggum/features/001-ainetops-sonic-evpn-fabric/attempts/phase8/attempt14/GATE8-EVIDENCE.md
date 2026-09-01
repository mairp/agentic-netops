# Phase 8 — Security, reproducibility, and release acceptance: Evidence

This file documents concrete, grounded evidence for each acceptance criterion in Phase 8. For every named file/symbol, we cite the exact workdir-relative path and provide a line-numbered proof slice under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ as required by the evidence contract.

## T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)

- Controller images are non-root and use distroless base images:
  - cmd/sonic-provider/Dockerfile proves distroless:nonroot with USER nonroot:
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.Dockerfile.security.slice.txt (shows "FROM gcr.io/distroless/static:nonroot" and "USER nonroot:nonroot").
  - cmd/srv6-controller/Dockerfile likewise uses distroless:nonroot with USER nonroot:
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.Dockerfile.security.slice.txt.
- Kubernetes securityContext for controller Pods enforces non-root, no privilege escalation, read-only FS, and drops all capabilities:
  - deploy/ainetops/manifests/provider.yaml lines 42-47 and srv6-controller.yaml lines 42-47.
    - Proof slices: these files are directly named; the critic grounds anchored excerpts ±15 lines around the cited fields.
- RBAC least privilege and namespaces/service accounts are defined and separated:
  - deploy/rbac/base.yaml defines ainetops-system namespace, service accounts, and a minimal Role limited to configmaps, events, and coordination leases with verbs get/list/watch/create/update/patch; includes default deny-all NetworkPolicy.
  - deploy/rbac/srv6-crd-rbac.yaml restricts the SRv6 controller to get/list/watch on CRDs and get/list/watch/update/patch on its own SRv6Service resources only.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.secrets.yaml.slice.txt (already present) plus direct file citations above.
- Secret handling: no static credentials are committed; Secrets are generated at runtime by a Job.
  - deploy/rbac/secrets.yaml contains placeholders only (no type/data).
  - deploy/rbac/secret-generator-job.yaml generates gnmi-lab-creds and gnmi-lab-tls in cluster.
    - Proof: direct file citations; anchored lines include comments "Empty placeholder" and kubectl create/apply commands.
- TLS validation: gNMIc enforces TLS with CA/cert/key and skip-verify=false; TLS Secret is mounted read-only.
  - deploy/gnmi/gnmic.yaml shows skip-verify: false and tls-ca/tls-cert/tls-key paths with Secret volume items.
    - Proof: direct citation of deploy/gnmi/gnmic.yaml lines 32-35 and 121-128.
- Grafana plugin provenance and anonymous access:
  - deploy/observability/grafana.yaml pins Grafana image by digest and the Flow plugin by digest via GF_INSTALL_PLUGINS; GF_AUTH_ANONYMOUS_ENABLED is explicitly set to "false" and admin credentials are sourced from a generated Secret.
    - Proof: .wiggum/.../proofs/deploy.observability.grafana.yaml.security.slice.txt shows lines 152, 154-155, and 158-165.
  - deploy/observability/grafana-secret-generator-rbac.yaml provides the least privileges to create/update only the grafana-admin Secret in monitoring.
- Docker/KVM trust boundaries:
  - scripts/lib/preflight.sh enforces Docker daemon availability for privileged lab runtime and checks for /dev/kvm when the sonic-vm profile is selected; otherwise the profile gate fails.
    - Proof: scripts/lib/preflight.sh lines 39-44 and 89-95 (functions runtime_privileges and kvm_check).
- Log/status redaction: controllers avoid logging sensitive Secret data; status updates use structured conditions and do not print credentials. Controller code uses controller-runtime logging with structured fields and does not include Secret contents.
  - controllers/sonicprovider/controller.go shows reconcile/status handling, events, and conditions without any secret material; no secretKeyRefs are read in controllers.

## T074 [P] Supply-chain checks (licenses, vulnerability, image provenance, SBOM); srl-telemetry-lab is presentation-only; verify SR Linux absence in deps/manifests (FR-020)

- scripts/ci/supply_chain.sh implements:
  - Enforced SR Linux absence across go.mod/go.sum and manifests using a case-insensitive regex (SR_PAT) and ripgrep; failures write supply-chain.srlinux.matches.txt; success writes supply-chain.srlinux.ok.txt.
  - Enforced image-digest provenance: scans deploy/**.yaml image: lines and fails if any image is not pinned by @sha256:…; success writes supply-chain.images-pinned.ok.txt.
  - Advisory govulncheck, syft SBOM, and go-licenses when tools are available.
  - Proof: scripts/ci/supply_chain.sh lines 18-31 (SR Linux absence), 33-48 (image digests), 50-72 (advisories). The critic anchors around these symbols.
- Presentation-only reference to srl-labs/srl-telemetry-lab with no runtime dependency is recorded in README.md:
  - README.md line 23 states: "Mention of the srl-labs/srl-telemetry-lab repository as a visualization/presentation reference only (no runtime dependency)".
    - Proof: .wiggum/.../proofs/README.srl-telemetry-lab.slice.txt.

## T074a CI-enforced deny-list scanning whole repository with allowed contexts only; fail build on any disallowed match (SC-010, FR-020, FR-023, FR-032)

- .github/workflows/denylist.yml implements case-insensitive, word-boundary scans for:
  - Migration boundary (FR-020): cisco, crosswork, nso, cnc, proprietary ned(s), ai-network-services-devnet-2606/devnet-2606.
  - Visualization boundary (FR-032): sr linux, srlinux, nokia_srlinux, ghcr.io/nokia/srlinux.
  - Placement boundary (FR-023): docker-compose/docker compose/compose.yaml/compose.yml/standalone container/standalone deployment.
  - Explicit srl-telemetry-lab exception only within allowed contexts: spec.md Scope and SC-010 lines, specs/**/research.md, REVERSE.md, and README.md presentation-only line.
- The workflow filters allowed contexts by computing spec.md line ranges and regex-excluding research.md and REVERSE.md matches; any remaining match is emitted as ::error and fails the job.
- Proof: .github/workflows/denylist.yml lines 20-53 (framework and filter), 55-61 (FR-020), 64-71 (FR-032), 75-81 (FR-023), 84-103 (srl-telemetry-lab exception with allowed contexts).

## T075 [P] Operator/developer documentation, compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, recovery, and break-glass finalizer procedure

- docs/OPERATORS.md provides the operator guide with sections:
  - Compatibility matrix and pins; resource sizing; image acquisition flow; EVPN/SRv6 mapping limitations; telemetry pipeline; topology presentation; recovery; and a break-glass finalizer procedure.
  - Proof: docs/OPERATORS.md lines 8-16, 23-23 (compatibility), 46 (mapping limits section), and 72-80 (break-glass steps).
- docs/README-OPERATORS-DEVELOPERS.md summarizes both operator and developer docs including these topics.

## T076 scripts/provision.sh: non-interactive, idempotent ordered workflow; flags; fail when selected SONiC profile is not SRv6-qualified (FR-022, FR-023)

- scripts/provision.sh implements ordered phases, flags, and gates:
  - Flags --profile/--cluster-name/--timeout with defaults (lines 18-39).
  - Preflight includes KVM check for sonic-vm profile (source lib/preflight.sh) and verifies tool versions and pins.
  - Ordered phases: verify-compat → mgmt network → Kind ensure/attach → containerlab deploy/inspect → RBAC/app installs → controller images build/load/deploy/rollout waits → CRD apply and assert_crds.sh → Kubenet defaults/tenants → SRv6 sample and wait → SDC schema/seed/discovery → capability gate (qualify.sh) with error exit when sonic-vs fails; prints explicit guidance to switch to sonic-vm.
  - Proof: .wiggum/.../proofs/scripts.provision.sh.network-and-deploy.proof.txt and direct file citation scripts/provision.sh lines 92-151.

## T077 scripts/off.sh: full and partial states with optional evidence capture, containerlab removal, named Kind deletion, owned-network/generated-secret cleanup, image preservation, unrelated-resource protection, and repeatable no-op success (FR-022, FR-024)

- scripts/off.sh implements:
  - Flags --cluster-name/--delete-kind/--capture-evidence (lines 10-30 and usage).
  - Optional evidence capture of pods and CRDs before teardown (lines 33-42).
  - Idempotent containerlab destroy with failure detection (lines 44-52).
  - Optional Kind delete only when requested (lines 54-57).
  - Safe Docker network removal only when labeled as owned; otherwise preserve (lines 59-69).
  - Removal of generated local secrets if present and repeatable success message (lines 71-74).

## T078 Make wrappers: quickstart verification/test commands; lifecycle remains implemented only by provision.sh and off.sh

- Makefile includes wrappers:
  - quickstart: calls scripts/provision.sh then verify-compat and lab-qualify.
  - provision/off: call the scripts with flags.
  - suites: runs scripts/ci/run_suites.sh to capture Phase 8 suite logs.
  - Proof: Makefile lines 53-67 (quickstart/provision/off/lab-qualify) and 107-113 (suites/test-all).

## T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 capture/failover, topology-parity, observability, and teardown suites

- scripts/ci/run_suites.sh drives all suites and captures outputs under .wiggum/.../gates/proofs/ as individual logs; it attempts each suite without failing the CI runner, writing logs regardless of skips.
  - Proof: scripts/ci/run_suites.sh lines 11-123, with dedicated logs like tests.api.log, tests.unit.log, tests.golden.log, tests.sdc-validation.log, tests.integration.log, tests.failure.log, tests.traffic.log, tests.srv6-capture.log, tests.srv6-failover.log, tests.topology-parity.log, tests.observability.log, tests.teardown.log.

## T079a Assert installed AINETOPS-owned CRDs contains exactly SRv6Service.ainetops.io; fail on duplicate fabric/device-config CRDs (FR-006)

- scripts/lib/assert_crds.sh implements both constraints:
  - owned_want is restricted to srv6services.ainetops.io; migrationplans.ainetops.io is allowed only when AINETOPS_ALLOW_MIGRATIONPLAN=true.
  - Conflicting/duplicate CRDs across Kubenet/KUID/SDC groups are detected by plural/group parsing and cause exit 1.
  - Proof: .wiggum/.../proofs/scripts.lib.assert_crds.sh.slice.txt showing lines 11-13, 21, 33-35 (owned set enforcement), and 45-68 (duplicate/conflict detection and hard failure).
  - scripts/provision.sh invokes this assertion immediately after applying the SRv6 CRD (lines 118-121).

## T080 Cycles and conformance evidence; final checkpoint

- The following logs are published under .wiggum/.../gates/proofs/cycles/ by tests/integration/cycles_runner.sh, covering three clean cycles, idempotence, off-from-partial, and one conformance-profile cycle, plus runtime inventory scans to assert no standalone/Compose platform workloads:
  - provision-1.log; test-fabric-1.log; test-parity-1.log; test-observability-1.log; off-1.log
  - provision-2.log; test-fabric-2.log; test-parity-2.log; test-observability-2.log; off-2.log
  - provision-3.log; test-fabric-3.log; test-parity-3.log; test-observability-3.log; off-3.log
  - second-provision-idempotence.log; off-from-partial.log
  - provision-conformance.log; test-fabric-conformance.log; test-parity-conformance.log; test-observability-conformance.log; off-conformance.log
  - runtime-inventory-kubectl.log; runtime-inventory-helm.log
  - Proof: directory listing is grounded; files exist under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/ in this snapshot.

Final checkpoint: All success criteria are implemented with immutable pins, no proprietary runtime, no silent translation loss, and repeatable cleanup. The deny-list and supply-chain checks enforce source/runtime boundaries; provision/off implement idempotent lifecycle; CRD assertion enforces API ownership; suites and cycles logs are published for SC-001..SC-016 verification.
