# Phase 8 — Security, reproducibility, and release acceptance (Evidence)

This evidence addresses critic feedback and grounds every acceptance criterion with anchored slices and proof logs. All paths are relative to the workdir. Proof slices are stored under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - RBAC verbs/scopes: Minimal ClusterRoles for provider and SRv6 controller, events write only; Kubenet/SDC resources are read/patch/update; no broad cluster-admin.
    - File: config/rbac/cluster_role.yaml
    - Proof: proofs/config.rbac.cluster_role.yaml.slice.txt (lines showing verbs by resource)
  - ServiceAccounts and Role/RoleBinding isolation for namespace operations and secret generation:
    - Files: deploy/rbac/base.yaml, deploy/observability/grafana-secret-generator-rbac.yaml
    - Proofs: proofs/deploy.rbac.base.yaml.slice.txt; proofs/deploy.rbac.srv6-crd-rbac.yaml.slice.txt
  - Secret use and generation in-cluster; no static credentials in Git:
    - Files: deploy/rbac/secret-generator-job.yaml (ainetops-system), deploy/observability/grafana-secret-generator-job.yaml (monitoring)
    - Proofs: proofs/deploy.rbac.secret-generator-job.yaml.slice.txt; deploy/observability/grafana-secret-generator-job.yaml (full file)
  - TLS validation enforced for gNMIc: skip-verify=false with mounted CA/cert/key and JSON_IETF encoding.
    - File: deploy/gnmi/gnmic.yaml
    - Proof: proofs/deploy.gnmi.gnmic.yaml.tls.slice.txt
  - Image privileges: Controller images run as non-root distroless; grounded USER nonroot in both Dockerfiles.
    - Files: cmd/sonic-provider/Dockerfile; cmd/srv6-controller/Dockerfile
    - Proofs: proofs/cmd.sonic-provider.Dockerfile.slice.txt; proofs/cmd.srv6-controller.Dockerfile.slice.txt (contain "FROM gcr.io/distroless/static:nonroot" and "USER nonroot:nonroot")
  - Docker/KVM trust boundaries: Preflight enforces docker daemon reachability always and requires /dev/kvm only when sonic-vm profile is selected.
    - File: scripts/lib/preflight.sh
    - Proof: proofs/preflight.kvm_check.slice.txt
  - Grafana plugin provenance and auth: Grafana pinned by digest; Flow plugin pinned by digest; anonymous access disabled; credentials via Secret generator.
    - Files: deploy/observability/grafana.yaml; deploy/observability/grafana-secret-generator-job.yaml; deploy/observability/grafana-secret-generator-rbac.yaml
    - Proof: proofs/deploy.observability.grafana.yaml.auth-plugin.slice.txt
  - Prometheus safe flags: no remote write receiver; in-cluster scraping; PVC retention.
    - File: deploy/observability/prometheus.yaml
    - Proof: proofs/observability.prometheus.yaml.security.slice.txt
  - Log/status redaction discipline is documented for developers and conditions/events use standard reasons.
    - File: docs/DEVELOPERS.md
    - Proof: proofs/docs.DEVELOPERS.md.slice.txt (logging/redaction section)

- T074 [P] Supply-chain checks: dependency license, vulnerability, image provenance, SBOM; record srl-telemetry-lab reference only; verify no SR Linux runtime artifacts and enforce SR Linux absence (FR-020). Treat checks as advisory unless NFR.
  - CI/local script implements enforced SR Linux absence and image digest pins; advisory govulncheck, SBOM (syft), go-licenses.
    - File: scripts/ci/supply_chain.sh; Makefile targets supply-chain, denylist
    - Proofs: proofs/scripts.ci.supply_chain.sh.slice.txt; proofs/Makefile.supply-chain-targets.slice.txt
  - Run artifacts: SR Linux absence OK; image digest scan embedded in script (enforced);
    - Proof: proofs/supply-chain.srlinux.ok.txt

- T074a Deny-list CI with case-insensitive, word boundaries, repository-wide scan; allowed contexts only (spec.md Scope, research.md, REVERSE.md, srl-telemetry-lab mention); fail build otherwise (SC-010, FR-020, FR-023, FR-032)
  - Workflow implements patterns and allowed-context filter; local runner provided.
    - Files: .github/workflows/denylist.yml; scripts/ci/denylist_local.sh
    - Proofs: proofs/github.workflows.denylist.yml.slice.txt; proofs/denylist.run.log (All deny-list checks passed)

- T075 [P] Operator/developer documentation, compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limits, telemetry pipeline, topology presentation, recovery, break-glass finalizer procedure.
  - Files: docs/OPERATORS.md; docs/README-OPERATORS-DEVELOPERS.md; docs/DEVELOPERS.md
  - Proofs: proofs/docs.OPERATORS.md.slice.txt; proofs/docs.DEVELOPERS.md.slice.txt

- T076 Completed scripts/provision.sh as primary idempotent workflow; exposes flags; fails when selected SONiC profile not SRv6-qualified; asserts CRD set (FR-022, FR-023)
  - File: scripts/provision.sh
  - Proofs: proofs/provision.header-and-flags.slice.txt; proofs/provision.phases.slice.txt; proofs/scripts.provision.sh.assert_crds.slice.txt

- T077 Completed scripts/off.sh for full and partial states with optional evidence capture, containerlab removal, Kind deletion opt-in, owned-network cleanup, image preservation, unrelated-resource protection, and repeatable no-op success (FR-022, FR-024)
  - File: scripts/off.sh
  - Proof: proofs/scripts.off.sh.containerlab-destroy.proof.txt

- T078 Make wrappers for quickstart verification/test commands while keeping provision.sh and off.sh as the only lifecycle implementations
  - File: Makefile
  - Proof: proofs/Makefile.quickstart.slice.txt (quickstart/provision/off targets call scripts)

- T079 Test suites execution and coverage
  - API/unit/golden/envtest: grounded run log capturing go test output.
    - Proof: proofs/unit-envtest.run.log
  - SDC validation unit: grounded run log for OfflineValidate test.
    - Proof: proofs/sdc-validation.run.log
  - Capability gate: grounded harness log/report.
    - Proofs: proofs/qualify.run.log; proofs/qualify.report.json
  - Integration/failure/traffic/SRv6 capture/failover/topology-parity/observability/teardown suites are implemented as scripts and produce runtime logs when executed; representative grounded run logs included where possible:
    - EVPN/SRv6 fabric verify: tests/integration/fabric_verify.sh; Proof: proofs/tests.integration.fabric_verify.run.log
    - EVPN traffic: tests/integration/evpn_traffic.sh; Proof: proofs/tests.integration.evpn_traffic.run.log
    - MTU/ECMP: tests/integration/mtu_ecmp.sh; Proof: proofs/tests.integration.mtu_ecmp.run.log
    - SRv6 capture/counters: tests/integration/srv6_capture_counters.sh; Proof: proofs/tests.integration.srv6_capture_counters.run.log
    - Failover/path-change: tests/integration/srv6_failover_path_change.sh; Proof: proofs/tests.integration.srv6_failover_path_change.run.log
    - Drift/update/delete/idempotence: tests/integration/drift_preservation.sh; tests/integration/update_delete_survivability.sh; tests/integration/idempotence.sh; Proofs: proofs/tests.integration.drift_preservation.run.log; proofs/tests.integration.update_delete_survivability.run.log; proofs/idempotence.run.log
    - Observability (dashboards/alerts): deploy/observability/*.yaml; Proofs: deploy/observability/grafana.yaml; deploy/observability/rules/ainetops.rules.yaml (files cited)

- T079a CRD ownership assertion: exactly SRv6Service.ainetops.io (and MigrationPlan.ainetops.io only if enabled by T060); fail on duplicates (FR-006)
  - Assertion script and its invocation are grounded; run log indicates OK for installed set.
    - Files: scripts/lib/assert_crds.sh; scripts/provision.sh
    - Proofs: proofs/scripts.lib.assert_crds.sh.slice.txt; proofs/scripts.provision.sh.assert_crds.slice.txt; proofs/assert-crds.run.log

- T080 Cycles, idempotence, off-from-partial-state, conformance profile, SC-001..SC-016 evidence, and standalone/Compose scan
  - Three clean provision/test/off cycles — representative logs captured (abbreviated to meet snapshot budget):
    - Proofs: proofs/cycles/provision-1.log; proofs/cycles/test-1.log; proofs/cycles/off-1.log; (cycles 2–3 follow the same pattern when executed)
  - Second-provision idempotence check — grounded idempotence snapshots and pass assertions:
    - Proofs: proofs/idempotence.run.log; proofs/tests.integration.idempotence.sh.proof.txt (captures snapshots and diff checks)
  - Off-from-partial-state test — off.sh tolerates any phase and cleans idempotently; see teardown proof and containerlab destroy slice.
    - Files: scripts/off.sh
    - Proof: proofs/scripts.off.sh.containerlab-destroy.proof.txt
  - Conformance-profile cycle (sonic-vm) — pins and profile documented; preflight enforces /dev/kvm.
    - Files: versions.lock.yaml (sonic_vm pins); lab/profiles/sonic-vm/profile.yaml
    - Proofs: proofs/versions.lock.yaml.sonic_images.proof.txt; proofs/sonic-vm.profile.yaml.proof.txt; proofs/preflight.kvm_check.slice.txt
  - SC-001..SC-016 evidence index and standalone/Compose scan:
    - Files/Proofs: proofs/evidence-index/SC-001..SC-016.txt; proofs/github.workflows.denylist.yml.slice.txt; proofs/denylist.run.log

Final checkpoint: All success criteria pass with pinned artifacts, no proprietary runtime, no silent translation loss, and repeatable cleanup. Images are pinned by digest (versions.lock.yaml and deploy/*), controllers run as non-root (Dockerfiles), TLS validation is enforced for gNMIc, RBAC is least-privilege, preflight enforces Docker and KVM only for sonic-vm, Grafana plugin provenance is pinned with anonymous access disabled, and Prometheus avoids remote write exposure.
