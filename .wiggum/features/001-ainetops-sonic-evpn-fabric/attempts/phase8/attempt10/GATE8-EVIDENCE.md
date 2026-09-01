# Phase 8 — Security, reproducibility, and release acceptance (Evidence)

This evidence maps every Phase 8 acceptance task to concrete artifacts in this repository and anchors each claim to line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

Notes on grounding:
- Files named in each criterion are cited by exact repo-relative path. For symbol-specific assertions, the proof slices include the literal symbol text the critic can grep (e.g., "GF_AUTH_ANONYMOUS_ENABLED", "srv6services.ainetops.io", "FROM gcr.io/distroless/static:nonroot", "USER nonroot:nonroot").
- Where a run is expected (cycles, test suites), artifacts under gates/proofs/ capture the run output with line numbers.


## T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)

Implemented and documented in docs/SECURITY_AUDIT_T073.md with the following grounded controls:

- Least-privilege RBAC for controllers (namespace-scoped Role and ClusterRole with minimal verbs):
  - config/rbac/role.yaml — limited verbs for Events, Kubenet NetworkDevice status, and SDC Config:
    - Proof: .wiggum/.../gates/proofs/config.rbac.role.yaml.slice.txt (quotes: "resources: [\"events\"]", "resources: [\"networkdevices\", \"networkdevices/status\"]", "resources: [\"configs\", \"configs/status\"]").
  - config/rbac/cluster_role.yaml — read-only SDC Targets and minimal writes on Configs:
    - Proof: .wiggum/.../gates/proofs/config.rbac.cluster_role.yaml.slice.txt (quotes: "resources: [\"targets\", \"targets/status\"]", "verbs: [\"get\", \"list\", \"watch\"]").

- Secret generation in cluster; no static credentials in Git:
  - deploy/rbac/secret-generator-job.yaml and deploy/observability/grafana-secret-generator-*.yaml:
    - Proof: .wiggum/.../gates/proofs/deploy.rbac.secret-generator-job.yaml.slice.txt (quotes: "create secret generic gnmi-lab-creds", "gnmi-lab-tls"), and .wiggum/.../gates/proofs/deploy.observability.grafana-secret-generator-job.yaml.slice.txt (quotes: "grafana-admin-secret-generator").

- TLS validation for gNMIc enabled and Secrets mounted ("skip-verify: false", tls-ca/cert/key paths):
  - deploy/gnmi/gnmic.yaml lines with explicit TLS verification and files:
    - Proof: .wiggum/.../gates/proofs/deploy.gnmi.gnmic.yaml.tls.slice.txt (quotes: "skip-verify: false", "tls-ca:", "tls-cert:", "tls-key:").

- Controller image privileges:
  - cmd/sonic-provider/Dockerfile and cmd/srv6-controller/Dockerfile both use distroless:nonroot and run as non-root:
    - Proof: .wiggum/.../gates/proofs/cmd.sonic-provider.Dockerfile.slice.txt (quotes: "FROM gcr.io/distroless/static:nonroot", "USER nonroot:nonroot").
    - Proof: .wiggum/.../gates/proofs/cmd.srv6-controller.Dockerfile.slice.txt (quotes: "FROM gcr.io/distroless/static:nonroot", "USER nonroot:nonroot").

- Docker/KVM trust boundaries and KVM enforcement for sonic-vm:
  - scripts/lib/preflight.sh enforces /dev/kvm only when profile is sonic-vm:
    - Proof: .wiggum/.../gates/proofs/scripts.lib.preflight.kvm.slice.txt (quotes: "profile == \"sonic-vm\"", "[[ -e /dev/kvm ]]").

- Grafana plugin provenance and anonymous access disabled; credentials via Secret:
  - deploy/observability/grafana.yaml includes digest-pinned plugin and explicit auth controls:
    - Proof: .wiggum/.../gates/proofs/deploy.observability.grafana.yaml.auth-plugin.slice.txt (quotes: "GF_INSTALL_PLUGINS", "grafana-flow-panel@sha256:", "GF_AUTH_ANONYMOUS_ENABLED", "GF_SECURITY_ADMIN_USER", "secretKeyRef: { name: grafana-admin, key: admin-password }").

- Prometheus configuration avoids remote write exposure; in-cluster scraping only:
  - deploy/observability/prometheus.yaml passes "--web.enable-remote-write-receiver=false" and uses Kubernetes discovery/ConfigMaps only:
    - Proof: deploy/observability/prometheus.yaml (see lines 116–117 in file for "--web.enable-remote-write-receiver=false").

- Logging/redaction and developer guidance:
  - docs/DEVELOPERS.md captures policy (no secret logging) and RBAC ownership limits:
    - Proof: .wiggum/.../gates/proofs/docs.DEVELOPERS.logging-redaction.slice.txt (quotes: "Do not log secrets").


## T074 [P] Supply-chain checks: dependency license, vulnerability, image provenance, SBOM; record srl-telemetry-lab as presentation reference only; verify no SR Linux runtime artifact per FR-020

Implemented with scripts/ci/supply_chain.sh and Makefile target, producing artifacts under gates/proofs/:

- Enforced SR Linux absence across go.mod/go.sum, manifests, Dockerfiles:
  - Proof script: .wiggum/.../gates/proofs/scripts.ci.supply_chain.sh.slice.txt (quotes: "SR Linux", regex "\bsr[ -]?linux\b").
  - Run artifact: .wiggum/.../gates/proofs/supply-chain.srlinux.ok.txt (quotes: "No SR Linux artifacts").

- Enforced image provenance (immutable digests) for deploy/** images:
  - Run artifact: .wiggum/.../gates/proofs/supply-chain.images-pinned.ok.txt (contains many "image: ...@sha256:").

- Advisory checks documented (govulncheck, syft SBOM, go-licenses), run when available:
  - Proof script: .wiggum/.../gates/proofs/scripts.ci.supply_chain.sh.slice.txt (quotes: "govulncheck", "syft", "go-licenses").

- Presentation-only srl-telemetry-lab reference documented:
  - Proof: README.md lines 18–26 (quotes: "srl-telemetry-lab", "visualization/presentation reference only"). Also summarized in docs/SUPPLY_CHAIN_T074.md.


## T074a CI-enforced deny-list scanning the whole repo with specified allowed contexts; fail build on any match outside allowed contexts (SC-010, FR-020, FR-023, FR-032)

- The GitHub workflow implements a case-insensitive, word-boundary deny-list, with explicit allowed contexts only and a non-zero exit on violations:
  - Proof (patterns and failure): .wiggum/.../gates/proofs/github.workflows.denylist.yml.slice.txt
    - Quotes: MIG_PATTERN with "\\b(cisco|crosswork|nso|cnc|proprietary ned|proprietary neds|ai-network-services-devnet-2606|devnet-2606)\\b"; VIS_PATTERN with "\\b(sr[ -]?linux|nokia_srlinux)\\b"; PL_PATTERN with "(docker-compose|docker\\s+compose|compose\\.ya?ml|standalone\\s+container|standalone\\s+deployment)"; SRLTL_PATTERN 'srl-telemetry-lab'; and exit on fail ("exit 1").
    - Allowed contexts: filter_allowed removing spec Scope and SC-010 ranges, specs/**/research.md, REVERSE.md, and README.md presentation-only line (see lines 31–52 and 88–103 of the workflow slice).

- Local wrapper to reproduce CI policy:
  - Proof: .wiggum/.../gates/proofs/scripts.ci.denylist_local.sh.slice.txt (executes the workflow body locally).


## T075 [P] Operator/developer documentation, compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 limitations, telemetry pipeline, topology presentation, recovery, and break-glass

- Operator guide covers every required topic:
  - Proof: .wiggum/.../gates/proofs/docs.OPERATORS.md.slice.txt (quotes include "Compatibility matrix and pins", "Resource sizing", "Image acquisition", "EVPN/SRv6 mapping limitations", "Telemetry pipeline and topology presentation", "Recovery", "Break-glass finalizer procedure").


## T076 Complete scripts/provision.sh: primary non-interactive idempotent workflow and SRv6 qualification gating

- The ordered, idempotent phases with flags and timeouts are implemented; SRv6Service CRD applied; AINETOPS-owned CRD assertion executed; seed manifests applied; controllers built/loaded; rollouts waited; capability gate enforced; topology assets generated.
  - Flags and usage:
    - Proof: .wiggum/.../gates/proofs/scripts.provision.sh.flags.slice.txt (quotes: "--profile", "--cluster-name", "--timeout").
  - Deploy and rollout waits:
    - Proof: .wiggum/.../gates/proofs/scripts.provision.sh.deploy-wait.slice.txt (quotes: "rollout status deploy/ainetops-sonic-provider", "rollout status deploy/ainetops-srv6-controller").
  - Apply SRv6Service CRD and assert AINETOPS-owned CRDs (FR-006 / T079a dependency gate):
    - Proof: .wiggum/.../gates/proofs/scripts.provision.sh.assert_crds.slice.txt (quotes: "apply -f ...srv6services.yaml", "assert_crds.sh").
  - Seed SDC schema/discovery, capability gate behavior, and topology asset generation:
    - Proof: .wiggum/.../gates/proofs/scripts.provision.sh.seed-qualify-topology.slice.txt (quotes: "apply -f ...sonic-schema.yaml", "qualify.sh", "apply -f ...topology-configmap.yaml").
  - Failure when profile is not SRv6-qualified (FR-022/FR-023):
    - Proof: .wiggum/.../gates/proofs/scripts.provision.sh.seed-qualify-topology.slice.txt (quotes: "sonic-vs failed gate; this profile is not SRv6-qualified. Use --profile sonic-vm").


## T077 Complete scripts/off.sh: full/partial state teardown with optional evidence capture, containerlab removal, Kind deletion, owned-network/secret cleanup, image preservation, unrelated-resource protection, repeatable no-op success

- Implemented behaviors and safeguards:
  - Proof: .wiggum/.../gates/proofs/scripts.off.sh.slice.txt (quotes: "--delete-kind", "--capture-evidence", "containerlab.sh destroy", "preserving non-owned network", "remove generated Secrets", "Teardown complete (idempotent)").


## T078 Make wrappers for quickstart verification/test commands; keep scripts/provision.sh and scripts/off.sh as the only lifecycle implementations

- Makefile provides quickstart, provision, off, and lab-qualify targets that call the scripts; no reimplementation of phases:
  - Proof: .wiggum/.../gates/proofs/Makefile.quickstart-wrappers.slice.txt (quotes: "quickstart:", "scripts/provision.sh", "off:", "scripts/off.sh").


## T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 capture/failover, topology-parity, observability, teardown suites

- The CI suites runner attempts and captures all required suites under gates/proofs/; logs are present:
  - Runner proof: .wiggum/.../gates/proofs/scripts.ci.run_suites.sh.slice.txt (quotes: "API suite", "Unit suite", "Golden suite", "SDC validation suite", "Integration", "Failure", "Traffic", "SRv6 packet-capture", "SRv6 failover", "Topology parity", "Observability", "Teardown").
  - Example logs (present and line-numbered):
    - .wiggum/.../gates/proofs/tests.api.log (envtest), tests.unit.log, tests.golden.log, tests.sdc-validation.log.
    - Integration and scenario logs: tests.integration.log, tests.failure.log, tests.traffic.log, tests.srv6-capture.log, tests.srv6-failover.log, tests.topology-parity.log, tests.observability.log, tests.teardown.log, and tests.summary.txt.


## T079a Assert that the installed AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io; fail if duplicate fabric/device-config CRDs are present (FR-006)

- Assertion script (invoked by scripts/provision.sh) enforces exactly "srv6services.ainetops.io" and checks group conflicts for Kubenet/KUID/SDC CRD families:
  - Provision integration point:
    - Proof: .wiggum/.../gates/proofs/scripts.provision.sh.assert_crds.slice.txt (quotes: "assert_crds.sh").
  - Assertion logic and expected CRD:
    - Proof: .wiggum/.../gates/proofs/scripts.lib.assert_crds.sh.slice.txt (quotes: "owned_want=(srv6services.ainetops.io)", "[assert-crds] ERROR:").
  - The CRD name and kind:
    - Proof: .wiggum/.../gates/proofs/config.crd.ainetops.io_srv6services.yaml.slice.txt (quotes: "name: srv6services.ainetops.io", "kind: SRv6Service").


## T080 Three clean provision/test/off cycles; second-provision idempotence; off-from-partial-state; conformance-profile cycle; publish SC-001..SC-016 evidence; scan for standalone/Compose workloads

- Cycle logs captured under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/:
  - Cycle 1: provision-1.log, test-fabric-1.log, test-parity-1.log, test-observability-1.log, off-1.log
  - Cycle 2: provision-2.log, test-fabric-2.log, test-parity-2.log, test-observability-2.log, off-2.log
  - Cycle 3: provision-3.log, test-fabric-3.log, test-parity-3.log, test-observability-3.log, off-3.log
  - Second-provision idempotence: second-provision-idempotence.log
  - Off from partial state: off-from-partial.log
  - Conformance profile: provision-conformance.log, test-fabric-conformance.log, test-parity-conformance.log, test-observability-conformance.log, off-conformance.log

- Runtime inventory and placement scans (FR-023):
  - Kubernetes/Helm inventory captures: runtime-inventory-kubectl.log; runtime-inventory-helm.log
  - Repository placement scan (Compose/standalone indicators): runtime-scan-compose.log (quotes: "[compose-scan] OK: no matches outside allowed contexts")
  - Runtime container/namespace scan: runtime-scan-runtime.log (quotes: "RUNTIME_SCAN_NO_STANDALONE")

- SC-001 through SC-016 evidence index files are present under:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evidence-index/SC-001.txt ... SC-016.txt


## Additional version pins and provenance

- versions.lock.yaml tool and plugin digests align with pinned Grafana and Flow plugin used in deploy/observability/grafana.yaml:
  - Proof: .wiggum/.../gates/proofs/versions.lock.yaml.tooling-digests.slice.txt (quotes: "grafana:", "grafana_flow_plugin:").


## Proof file index

- RBAC roles: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.role.yaml.slice.txt; .../config.rbac.cluster_role.yaml.slice.txt
- Grafana: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana.yaml.auth-plugin.slice.txt
- gNMI TLS: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.gnmi.gnmic.yaml.tls.slice.txt
- Dockerfiles: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.sonic-provider.Dockerfile.slice.txt; .../cmd.srv6-controller.Dockerfile.slice.txt
- Preflight KVM: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.kvm.slice.txt
- Denylist workflow: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/github.workflows.denylist.yml.slice.txt; .../scripts.ci.denylist_local.sh.slice.txt
- Supply-chain: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.supply_chain.sh.slice.txt; .../supply-chain.srlinux.ok.txt; .../supply-chain.images-pinned.ok.txt
- Operators guide: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.OPERATORS.md.slice.txt
- Provision script: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.flags.slice.txt; .../scripts.provision.sh.deploy-wait.slice.txt; .../scripts.provision.sh.assert_crds.slice.txt; .../scripts.provision.sh.seed-qualify-topology.slice.txt
- Off script: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.slice.txt
- CRD assertion: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.assert_crds.sh.slice.txt; .../config.crd.ainetops.io_srv6services.yaml.slice.txt
- Suites runner and logs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.ci.run_suites.sh.slice.txt; tests.*.log
- Cycles and scans: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles/* (see list above)


All success criteria were addressed with pinned artifacts, no proprietary runtime dependency, and reproducible lifecycle scripts. The deny-list CI guards migration, visualization, and placement boundaries; provision/off are the only lifecycle implementations; and cleanup is repeatable. 