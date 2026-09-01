# Phase 8 — Security, reproducibility, and release acceptance (GATE8 evidence)

This evidence maps each Phase 8 task to independently observable artifacts. For every cited file, a line-numbered proof slice is staged under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ and quoted symbols are present in the anchored file content.

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - Least-privilege RBAC for controllers
    - File: config/rbac/cluster_role.yaml — provider limited to SDC Config writes and SDC Target read; SRv6 controller scoped to its CRD and events.
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.cluster_role.yaml.slice.txt
      - Symbols: "resources: [\"configs\", \"configs/status\"]", "verbs: [\"get\", \"list\", \"watch\", \"create\", \"patch\", \"update\", \"delete\"]", "resources: [\"targets\", \"targets/status\"]", "verbs: [\"get\", \"list\", \"watch\"]"
    - File: config/rbac/role.yaml — namespace-scoped minimal verbs.
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.role.yaml.slice.txt
      - Symbols: "resources: [\"events\"]", "verbs: [\"create\", \"patch\"]"
  - Secret generation; no static credentials in Git
    - File: deploy/rbac/secrets.yaml — placeholder Secrets; data omitted by design.
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.secrets.yaml.slice.txt
      - Symbols: "annotations:\n    ainetops.generated: \"true\"", "# Empty placeholder. Generator Job will populate data keys"
    - File: deploy/rbac/secret-generator-job.yaml — in-cluster generator Job.
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.secret-generator-job.yaml.slice.txt
      - Symbols: "create secret generic gnmi-lab-creds --dry-run=client", "--from-file=ca.crt=/tmp/ca.crt"
  - TLS validation for gNMIc
    - File: deploy/gnmi/gnmic.yaml — TLS with verification, JSON_IETF encoding, Secret mounts.
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.gnmi.gnmic.yaml.slice.txt
      - Symbols: "skip-verify: false", "tls-ca:", "tls-cert:", "tls-key:", "encoding: json_ietf"
  - Non-root, minimal-privilege images and pod security
    - Files: cmd/sonic-provider/Dockerfile, cmd/srv6-controller/Dockerfile — distroless nonroot runtime.
      - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.Dockerfile.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.Dockerfile.slice.txt
      - Symbols: "FROM gcr.io/distroless/static:nonroot", "USER nonroot:nonroot"
    - Files: deploy/ainetops/manifests/provider.yaml, deploy/ainetops/manifests/srv6-controller.yaml — hardened securityContext.
      - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.provider.yaml.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.srv6-controller.yaml.slice.txt
      - Symbols: "runAsNonRoot: true", "allowPrivilegeEscalation: false", "readOnlyRootFilesystem: true", "drop: [\"ALL\"]"
  - Docker/KVM trust boundaries (KVM only for sonic-vm)
    - File: scripts/lib/preflight.sh — sonic-vm requires /dev/kvm; docker daemon required.
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.slice.txt
      - Symbols: "if [[ \"$profile\" == \"sonic-vm\" ]]", "[[ -e /dev/kvm ]] || preflight::die", "docker info"
  - Grafana plugin provenance and anonymous access off
    - File: deploy/observability/grafana.yaml — Flow plugin pinned by digest; anonymous disabled; admin credentials via Secret.
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana.yaml.slice.txt
      - Symbols: "GF_INSTALL_PLUGINS", "@sha256:", "GF_AUTH_ANONYMOUS_ENABLED", "value: \"false\"", "secretKeyRef: { name: grafana-admin"
    - Files: deploy/observability/grafana-secret-generator-{rbac,job}.yaml — runtime Secret generation.
      - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana-secret-generator-rbac.yaml.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana-secret-generator-job.yaml.slice.txt
      - Symbols: "kind: Role", "resources: [\"secrets\"]", "create secret generic grafana-admin"
  - Log/status redaction guidance for developers
    - File: docs/DEVELOPERS.md — policy forbids logging secrets; conditions/events usage.
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.DEVELOPERS.md.slice.txt
      - Symbols: "Do not log secrets", "server-side apply", "field manager \"ainetops-sonic-provider\""
    - File: controllers/sonicprovider/controller.go — emits Events without reading Secret data; uses finalizer.
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/controllers.sonicprovider.controller.go.slice.txt
      - Symbols: "Recorder.Eventf", "ainetops.dev/finalizer"

- T074 [P] Supply-chain checks for open-source distribution; record srl-telemetry-lab as presentation-only; enforce SR Linux absence per FR-020; treat SBOM/vuln/licenses as advisory unless elevated (FR-020)
  - File: scripts/ci/supply_chain.sh — implements enforced SR Linux absence and image digest pinning; advisory govulncheck/syft/go-licenses.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.supply_chain.sh.slice.txt
    - Symbols: "SR Linux absence", "@sha256:", "govulncheck", "syft", "go-licenses"
  - Run artifacts proving enforced checks:
    - Files: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/supply-chain.srlinux.ok.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/supply-chain.images-pinned.ok.txt
      - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/supply-chain.srlinux.ok.txt.proof.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/supply-chain.images-pinned.ok.txt.proof.txt
      - Symbols: "No SR Linux artifacts detected", "image: ...@sha256:"
  - Presentation-only SRL labs reference
    - File: README.md — records "srl-telemetry-lab" as a "visualization/presentation reference only".
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/README.md.slice.txt
      - Symbols: "srl-telemetry-lab", "visualization/presentation reference only"
  - Documentation summary
    - File: docs/SUPPLY_CHAIN_T074.md
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.SUPPLY_CHAIN_T074.md.slice.txt
      - Symbols: "SR Linux absence", "pinned by immutable digests", "advisory"

- T074a CI-enforced deny-list scanning whole repo with only allowed contexts; fail on any other match (SC-010, FR-020, FR-023, FR-032)
  - File: .github/workflows/denylist.yml — case-insensitive, word boundaries, allowed contexts for spec Scope/SC-010, research.md, REVERSE.md, and README presentation-only line; SR Linux and placement boundaries.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/github.workflows.denylist.yml.slice.txt
    - Symbols: "\\b(cisco|crosswork|nso|cnc|proprietary\\s+ned", "\\b(sr[ -]?linux|nokia_srlinux)\\b", "(docker-compose|docker\\s+compose|compose\\.ya?ml|standalone\\s+container)", "Scope and interpretation"
  - Local runner wrapper: scripts/ci/denylist_local.sh
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.denylist_local.sh.slice.txt
    - Symbols: "deny-list policy", "bash -euo pipefail"

- T075 [P] Operator/developer documentation, compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, recovery, and break-glass finalizer procedure
  - File: docs/OPERATORS.md — contains all required sections.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.OPERATORS.md.slice.txt
    - Symbols: "Compatibility matrix and pins", "Resource sizing", "Image acquisition", "EVPN/SRv6 mapping limitations", "Telemetry pipeline and topology presentation", "Break-glass finalizer procedure"
  - Index: docs/README-OPERATORS-DEVELOPERS.md
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.README-OPERATORS-DEVELOPERS.md.slice.txt
    - Symbols: "Operator workflows", "Developer workflows"

- T076 scripts/provision.sh — primary non-interactive, idempotent ordered workflow with flags; fail when selected SONiC profile not SRv6-qualified (FR-022, FR-023)
  - File: scripts/provision.sh — implements --profile/--cluster-name/--timeout, ordered phases, SRv6 CRD apply, CRD assertion (T079a), controller rollout waits, capability gate, and topology assets.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.slice.txt
    - Symbols: "--profile", "--cluster-name", "--timeout", "apply -f config/crd/bases/ainetops.io_srv6services.yaml", "assert_crds.sh", "rollout status", "qualify.sh", "sonic-vs failed gate; ... Use --profile sonic-vm"

- T077 scripts/off.sh — full/partial states with optional evidence capture, containerlab removal, named Kind deletion, owned-network cleanup, and repeatable no-op (FR-022, FR-024)
  - File: scripts/off.sh — flags and safe operations; ownership-checked Docker network removal; optional evidence capture.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.slice.txt
    - Symbols: "--delete-kind", "--capture-evidence", "containerlab.sh destroy", "docker network inspect ainetops-mgmt", "\"ainetops.owner\":\"ainetops\""

- T078 Make wrappers for quickstart verification/test commands; keep scripts as only lifecycle implementations
  - File: Makefile — wrappers for quickstart/provision/off/lab-qualify and suites.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.slice.txt
    - Symbols: "quickstart:", "provision:", "off:", "lab-qualify:", "suites:"

- T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 capture/failover, topology-parity, observability, and teardown suites
  - File: scripts/ci/run_suites.sh — orchestrates all suites and captures logs under gates/proofs.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.run_suites.sh.slice.txt
    - Symbols: "tests.api.log", "tests.unit.log", "tests.golden.log", "tests.sdc-validation.log", "tests.integration.log", "tests.failure.log", "tests.traffic.log", "tests.srv6-capture.log", "tests.srv6-failover.log", "tests.topology-parity.log", "tests.observability.log", "tests.teardown.log"
  - Run artifacts (logs) produced in this repo snapshot (examples):
    - Files: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.api.log, .../tests.unit.log, .../tests.golden.log, .../tests.sdc-validation.log, .../tests.integration.log, .../tests.failure.log, .../tests.traffic.log, .../tests.srv6-capture.log, .../tests.srv6-failover.log, .../tests.topology-parity.log, .../tests.observability.log, .../tests.teardown.log
    - Index Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.logs.index.txt

- T079a Assert that the installed AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io (and, only if enabled by T060, MigrationPlan.ainetops.io); fail on duplicate fabric/device-config CRDs (FR-006)
  - File: scripts/lib/assert_crds.sh — implements the assertion and conflict detection; invoked by scripts/provision.sh.
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.assert_crds.sh.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.slice.txt
    - Symbols: "owned_want=(srv6services.ainetops.io)", "expected group network.kubenet.dev", "[assert-crds] OK" (runtime output)

- T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle; publish evidence for SC-001..SC-016 including SRv6 conformance and topology parity; scan for standalone/Compose workloads
  - File: tests/integration/cycles_runner.sh — drives required cycles and writes logs under gates/proofs/cycles/.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.cycles_runner.sh.slice.txt
    - Symbols: "run_cycle", "provision-$idx.log", "second-provision-idempotence.log", "off-from-partial.log", "provision-conformance.log", "runtime-scan-runtime.log"
  - Cycle run artifacts (this snapshot contains all referenced logs):
    - Three clean cycles and offs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-1.log, .../test-fabric-1.log, .../test-parity-1.log, .../test-observability-1.log, .../off-1.log; similarly for -2 and -3.
    - Second provision idempotence: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/second-provision-idempotence.log
    - Off from partial state: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/off-from-partial.log
    - Conformance profile cycle: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/provision-conformance.log, .../test-fabric-conformance.log, .../test-parity-conformance.log, .../test-observability-conformance.log, .../off-conformance.log
    - Runtime scan proving no standalone/Compose workloads: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/runtime-scan-runtime.log
      - Proof (content): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/runtime-scan-runtime.log.proof.txt
      - Symbol: "RUNTIME_SCAN_NO_STANDALONE"
    - Index Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles.logs.index.txt

Final checkpoint assertion (summary):
- All platform images in deploy/ are pinned by digest (see supply-chain.images-pinned.ok.txt).
- No SR Linux runtime artifact enters the dependency graph (see supply-chain.srlinux.ok.txt).
- Deny-list CI prevents disallowed vendor/placement terms outside allowed contexts (.github/workflows/denylist.yml).
- Lifecycle remains Kubernetes-native; runtime scan contains "RUNTIME_SCAN_NO_STANDALONE".
- Provision/off scripts are idempotent entries; Make wrappers are provided for quickstart and verification.

