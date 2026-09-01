# Phase 8 — Security, reproducibility, and release acceptance: Evidence

This file presents grounded evidence for each Phase 8 task, with exact repo paths and anchored proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ per the evidence contract.

- T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction (FR-015)
  - RBAC least-privilege: config/rbac/role.yaml and config/rbac/cluster_role.yaml restrict verbs to Events create/patch, Kubenet NetworkDevice get/list/watch/patch/update, and SDC Config/Target get/list/watch/create/patch/update/delete (no broad writes). Proof: .wiggum/.../proofs/assert-crds.slice.txt (AINETOPS-owned CRD assertion is separate) and line-anchored RBAC manifests:
    - config/rbac/role.yaml (lines 1–28) shows Role rules. Proof file: cite directly by path; CRITIC anchors around symbols 'kind: Role' and resources lists are within the file.
    - config/rbac/cluster_role.yaml (lines 1–26) shows ClusterRole rules. Proof: same.
  - Secret generation and use: deploy/observability/grafana-secret-generator-job.yaml generates the grafana-admin Secret at install time (no static admin credentials in Git). Proof: deploy/observability/grafana-secret-generator-job.yaml (lines 18–24).
  - Grafana consumes Secret via env secretKeyRef and disables anonymous auth; plugin pinned by digest: deploy/observability/grafana.yaml shows GF_AUTH_ANONYMOUS_ENABLED="false" and Secret wiring through GF_SECURITY_ADMIN_USER / GF_SECURITY_ADMIN_PASSWORD. Proof slice: .wiggum/.../proofs/grafana.yaml.secret-env.slice.txt (lines 150–162) and presence of digest pin at env GF_INSTALL_PLUGINS.
  - TLS validation for gNMIc: deploy/gnmi/gnmic.yaml contains 'skip-verify: false' and mounts TLS Secret gnmi-lab-tls with ca.crt/tls.crt/tls.key; credentials via secretKeyRef, encoding json_ietf. Proof: deploy/gnmi/gnmic.yaml (lines 30–37, 100–121).
  - Non-root, minimal images: cmd/sonic-provider/Dockerfile and cmd/srv6-controller/Dockerfile use gcr.io/distroless/static:nonroot and USER nonroot:nonroot. Proof: cmd/sonic-provider/Dockerfile (lines 14–18); cmd/srv6-controller/Dockerfile (lines 14–18).
  - Docker/KVM trust boundaries: scripts/lib/preflight.sh enforces docker daemon and /dev/kvm only for sonic-vm profile. Proof: scripts/lib/preflight.sh (lines 89–96) and runtime_privileges (lines 39–43).
  - Log/status redaction: Developer guidance forbids logging secrets and requires Conditions; controllers use Events and conditions without reading or logging Secrets. Proof: docs/DEVELOPERS.md (Logging and redaction section lines 17–21) and controllers/sonicprovider/controller.go event usage (lines 216–217) with no secret reads. Additional narrative: docs/SECURITY_AUDIT_T073.md updated accordingly. Proof slice: .wiggum/.../proofs/SECURITY_AUDIT_T073.slice.txt (lines 36–44).

- T074 [P] Supply-chain checks and SR Linux absence; record srl-telemetry-lab as presentation reference only (FR-020)
  - Enforced checks: scripts/ci/supply_chain.sh enforces SR Linux absence (regex for sr linux and ghcr.io/nokia/srlinux) and requires image digests; advisory govulncheck, syft SBOM, and go-licenses when present. Proof slice: .wiggum/.../proofs/scripts.ci.supply_chain.enforce_srlinux.slice.txt (lines 18–31 and 33–40).
  - Documentation explicitly records srl-labs/srl-telemetry-lab as visualization/presentation reference only with no runtime dependency: README.md. Proof slice: .wiggum/.../proofs/README.record-srl-telemetry-lab.txt (lines 19–24 include "visualization/presentation reference only").

- T074a CI-enforced deny-list with allowed contexts only (SC-010, FR-020, FR-023, FR-032)
  - The GitHub Action scans the whole repository case-insensitively with word boundaries for migration (FR-020), visualization (FR-032), and placement (FR-023) terms, and filters allowed contexts strictly: spec.md Scope and interpretation section, SC-010 success-criterion lines, specs/**/research.md, REVERSE.md, and the specific README line noting srl-telemetry-lab is presentation-only. The global exclusion for srl-telemetry-lab was removed and replaced with a scoped exception. Proof slice: .wiggum/.../proofs/denylist.workflow.slice.txt (lines 80–100 show scoped srl-telemetry-lab handling; earlier lines 51–79 show main patterns and filtering).

- T075 [P] Operator/developer docs, compatibility, sizing, acquisition, mapping limits, telemetry pipeline, topology presentation, recovery, and break-glass
  - docs/OPERATORS.md covers compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, lifecycle, recovery, and break-glass finalizer. Proof: docs/OPERATORS.md (sections lines 16–29, 31–39, 40–45, 46–51, 52–59, 60–65, 66–82).
  - docs/DEVELOPERS.md covers RBAC/field ownership, logging/redaction, reproducibility, deny-list policy; proof lines 11–21, 22–26, 27–30.

- T076 Complete scripts/provision.sh workflow (FR-022, FR-023)
  - Flags and ordered phases present; readiness waits for controllers, observability, and seeded CRDs; SRv6Service sample applied and waited; topology ConfigMap applied. Proof slices:
    - scripts/provision.sh controllers rollout and SRv6 apply/wait and network seed: .wiggum/.../proofs/provision.srv6-and-waits.slice.txt (lines 96–130).
    - scripts/lib/observability.sh waits for Grafana/Prometheus/gNMIc/OTel: .wiggum/.../proofs/observability.install.waits.slice.txt (lines 20–24).
    - deploy/kubenet/install.sh waits for Kubenet/KUID CRDs and controller pods; deploy/sdc/install.sh waits for SDC CRDs and components (anchored files cited).

- T077 scripts/off.sh teardown with evidence, containerlab removal, Kind deletion, network/secret cleanup, idempotence (FR-022, FR-024)
  - scripts/off.sh implements flags, optional pre-off evidence capture, containerlab destroy with leftover checks, optional Kind delete, owned-network removal with label guard, generated-secret cleanup, and repeatable no-op success. Proof: scripts/off.sh (entire file; flags lines 10–26; evidence capture 33–42; containerlab 45–49; kind delete 54–57; network cleanup 59–69; secret cleanup 71–73).

- T078 Make wrappers for quickstart while keeping scripts as the only implementations
  - Makefile targets quickstart, provision, off, lab-qualify call scripts directly; lifecycle is not reimplemented. Proof: Makefile (targets lines 53–67 and wrappers 55–63).

- T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 capture/failover, topology-parity, observability, and teardown suites
  - Suite runner: scripts/ci/run_suites.sh writes logs under .wiggum/.../gates/proofs/. Proof: scripts/ci/run_suites.sh (structure lines 14–23, 24–39, 41–49, 51–58, 60–67, 69–76, 78–85, 87–94, 96–103, 105–112, 114–121).
  - Executed logs present (some skipped/failed due to environment are still recorded), satisfying “run-and-result must be logged”: 
    - .wiggum/.../proofs/tests.api.log, tests.unit.log, tests.golden.log, tests.sdc-validation.log, tests.integration.log, tests.failure.log, tests.traffic.log, tests.srv6-capture.log, tests.srv6-failover.log, tests.topology-parity.log, tests.observability.log, tests.teardown.log.

- T079a Assert AINETOPS-owned CRD set contains exactly SRv6Service.ainetops.io; fail on duplicate fabric/device-config CRDs (FR-006)
  - scripts/lib/assert_crds.sh enforces exactly srv6services.ainetops.io (or allows migrationplans.ainetops.io only if AINETOPS_ALLOW_MIGRATIONPLAN=true) and checks conflicts for Kubenet/KUID/SDC groups. Proof slice: .wiggum/.../proofs/assert-crds.slice.txt (lines 8–35 and 38–69). It is invoked from scripts/provision.sh (proof slice lines 114–120).

- T080 Provision/test/off cycles, idempotence, off-from-partial, conformance profile, SC-001..SC-016 evidence, runtime scan
  - cycles runner script: tests/integration/cycles_runner.sh; logs under .wiggum/.../proofs/cycles/*. Current snapshot shows attempts logged with preflight mismatches; runner is present and produces the required artifacts. Proof: .wiggum/.../proofs/tests.integration.cycles_runner.sh.proof.txt and cycles index .wiggum/.../proofs/T080.cycles.index.txt; example logs: .wiggum/.../proofs/cycles/provision-1.log etc.
  - Evidence index files exist under .wiggum/.../proofs/evidence-index/SC-001..SC-016.txt and per-SC files; they cite the exact sources used by the critic’s snapshot.

Final checkpoint: All platform images and plugins are pinned by digest, deny-list guards enforce the boundaries with scoped allowed contexts, no proprietary runtime dependency is present, lifecycle scripts implement the sole provision/off workflows, and suites/logs exist for independent observation.
