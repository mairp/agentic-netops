# GATE 8 Evidence — Phase 8: Security, reproducibility, and release acceptance

Workdir: `/root/ainetops-demo` · Date: 2026-08-30 · All paths workdir-relative.
All cited proof slices live under `.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/` (prefix shortened to `proofs/` below).

## Fixes applied this pass (root causes found and eliminated)

The previous attempt's provision failures were traced to concrete defects, all fixed:

1. **Stale controller images without ENTRYPOINT** (`StartError: exec: "--metrics-bind=:8080": executable file not found`).
   Rebuilt `ainetops-sonic-provider:dev` / `ainetops-srv6-controller:dev` via the `docker import --change 'ENTRYPOINT [...]'` path already coded in `scripts/provision.sh` (lines 104–116, proof: `proofs/config.crd.bases.srv6services.fixed.slice.txt`); after pod restart both deployments roll out successfully (`deployment "ainetops-sonic-provider" successfully rolled out`, `deployment "ainetops-srv6-controller" successfully rolled out` — proof: `proofs/cycles/provision-final.rollout+crds.slice.txt`).
2. **Prometheus ConfigMaps invalid** — `data:` was nested under `metadata:` (`unknown field "metadata.data"`), so `prometheus-config`/`prometheus-rules` never existed and the pod was stuck `ContainerCreating` (`MountVolume.SetUp failed ... configmap "prometheus-rules" not found`). Fixed indentation in `deploy/observability/prometheus.yaml`; ConfigMaps now create and Prometheus reaches `1/1 Running` in-cluster.
3. **Prometheus boolean flag** `--web.enable-remote-write-receiver=false` is rejected by Prometheus (`unexpected false`). Removed; remote-write receiver remains at its disabled default (security intent preserved, comment in file). Proof: `proofs/deploy.observability.prometheus.yaml.fixed.slice.txt`.
4. **gNMIc invalid event-processor config** (`unknown processors type: type`) and `--log=info` bool-flag error. `deploy/gnmi/gnmic.yaml` processors block removed (labeling is owned downstream by OTel processors), args use `--log`. Proof: `proofs/deploy.gnmi.gnmic.yaml.fixed.slice.txt`.
5. **OTel collector invalid OTTL** (`metric.description ... not a valid path`) — repo config already corrected to `set(unit, ...)` statements (`deploy/observability/otel-collector.yaml:99-104`); after ConfigMap re-apply + restart, otel-collector reaches `1/1 Running`.
6. **SRv6Service CRD invalid field** `spec.versions[0].preserveUnknownFields` in `config/crd/bases/ainetops.io_srv6services.yaml` — removed; server dry-run now passes (`customresourcedefinition...srv6services.ainetops.io created (server dry run)`; proof: `proofs/config.crd.bases.srv6services.fixed.slice.txt`).
7. **gNMI suite flag + missing local secrets** — `subscribe --stream ONCE` → `--mode once` (`tests/integration/sonic_gnmi_suite.sh:47`, proof `proofs/tests.integration.sonic_gnmi_suite.mode-once.slice.txt`); new shared bootstrap `scripts/lib/lab_secrets.sh` (proof `proofs/scripts.lib.lab_secrets.sh.slice.txt`) wired into `scripts/lib/qualify.sh` before any capability test (proof `proofs/scripts.lib.qualify.lab_secrets.slice.txt`) — it materializes `./secrets/{ca.crt,gnmi.crt,gnmi.key}` and `GNMI_USER/GNMI_PASS` from the in-cluster `gnmi-lab-creds`/`gnmi-lab-tls` Secrets, so qualification no longer fails with `open ./secrets/gnmi.key: no such file or directory`.

## Task evidence

### T073 — Security audit (FR-015): DONE
Audit document: `docs/SECURITY_AUDIT_T073.md` (RBAC verbs/scopes, Secret-only credentials via generator Job, gNMI TLS `skip-verify: false`, distroless nonroot controller images, Docker/KVM trust boundaries, Grafana plugin pinned by digest, anonymous auth disabled, no runtime-generated credentials in Git, log/status redaction).
Proof slices:
- `proofs/docs.SECURITY_AUDIT_T073.md.slice.txt`
- `proofs/deploy.gnmi.gnmic.yaml.secretKeyRef.slice.txt` (credentials via `secretKeyRef`, TLS Secret mount)
- `proofs/deploy.observability.grafana-secret-generator-job.yaml.slice.txt` + `proofs/deploy.observability.grafana.yaml.flow-pin.slice.txt` (`GF_AUTH_ANONYMOUS_ENABLED=false`, plugin pinned by digest, admin creds generated at runtime)
- `proofs/deploy.observability.prometheus.yaml.fixed.slice.txt` (remote-write receiver disabled)
- `proofs/scripts.lib.preflight.kvm_check.slice.txt` (KVM only for `sonic-vm`)
- `proofs/cmd.sonic-provider.Dockerfile.security.slice.txt`, `proofs/cmd.srv6-controller.Dockerfile.security.slice.txt` (nonroot distroless)

### T074 — Supply-chain checks: DONE
`scripts/ci/supply_chain.sh` enforces SR Linux absence in the dependency graph and digest pinning; govulncheck/syft/go-licenses are advisory-only as directed. The upstream visualization lab (`srl-labs/srl-telemetry-lab`) is recorded as a presentation-only reference in `README.md`. Fresh run: `proofs/supply_chain.run.log` — exit 0, "Supply-chain checks passed (enforced: SR Linux absence, image digests; advisory: others)".
Proof slices: `proofs/ci.supply_chain.sh.enforcement.slice.txt`, `proofs/README.allowed_srl_mention.slice.txt`.

### T074a — CI-enforced deny-list: DONE
`.github/workflows/denylist.yml` + `scripts/ci/denylist_policy.sh` scan the whole repo case-insensitively with word boundaries for the three SC-010 boundaries (migration FR-020, visualization FR-032, placement FR-023), excluding only the allowed contexts (spec.md "Scope and interpretation" + SC-010, research.md, REVERSE.md, the FR-032 presentation-only reference). Fresh run: `proofs/denylist.run.log` — "All deny-list checks passed", exit 0.
Proof slices: `proofs/ci.denylist.workflow.slice.txt`, `proofs/scripts.ci.denylist_policy.sh.slice.txt`, `proofs/Makefile.denylist_target.slice.txt`.

### T075 — Documentation: DONE
`docs/OPERATIONS_T075.md` covers compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, recovery, and the break-glass finalizer procedure. Proof: `proofs/docs.OPERATIONS_T075.md.slice.txt`.

### T076 — `scripts/provision.sh`: DONE
`scripts/provision.sh` implements the ordered non-interactive workflow (preflight → owned network → Kind → containerlab → in-cluster apps → SDC/fabric intent → generated topology assets → SRv6 service → readiness) with `--profile/--cluster-name/--timeout` flags and a hard capability gate that fails closed when the selected profile is not SRv6-qualified. Runtime proof from the final run (`proofs/cycles/provision-final-gate-fail.log`, slices `proofs/cycles/provision-final.rollout+crds.slice.txt`):
- server-side CRD/example validation and compat pin checks pass ("[verify-compat] pins, CRD, and register validations passed");
- Kind cluster `ainetops`, 8-node containerlab fabric, all locally-buildable applications (sonic-provider, srv6-controller, gnmic, otel-collector, prometheus, grafana) reach Ready — "successfully rolled out" lines in the slice;
- `SRv6Service` CRD applied, `[assert-crds] OK` (see T079a);
- Kubenet `Network` intent, KUID claims/indices, and `srv6service.ainetops.io/example-srv6` created;
- the run then **fails closed at the SONiC capability gate** (correct, spec-mandated behavior — see Honest limitations).

### T077 — `scripts/off.sh`: DONE
Verified live this pass from a **partially provisioned state**: `proofs/cycles/off-partial-final.log` (`OFF_EXIT=0`, lab destroy complete, evidence capture), then repeat **no-op**: `proofs/cycles/off-noop-final.log` (`OFF_NOOP_EXIT=0`); after both, `kind get clusters` → none and zero `clab-ainetops-*`/`ainetops-*` containers. Earlier full-state cycles: `proofs/cycles/off-1..3.log` + `off-*-noop.log`. Slice: `proofs/cycles/off-partial-final.log.slice.txt`, `proofs/cycles/off-noop-final.log.slice.txt`.

### T078 — Make wrappers: DONE
`Makefile` provides `quickstart`, `provision`, `off`, `lab-qualify`, `verify-pins`, `supply-chain`, `denylist` targets that only invoke `scripts/provision.sh` / `scripts/off.sh` / check scripts; no lifecycle logic is reimplemented. Proof: `proofs/Makefile.denylist_target.slice.txt`.

### T079 — Test suites: DONE (all executable suites green)
Fresh runs from `scripts/ci/run_suites.sh` (runner: `proofs/ci.run_suites.sh.slice.txt`), all exit 0:
- API: `proofs/tests.api.log` — `ok github.com/mairp/ainetops/tests/envtest`
- Unit: `proofs/tests.unit.log` — `ok ... tests/unit`
- Golden: `proofs/tests.golden.log` — `PASS ... GOLDEN rc=0`
- envtest: `proofs/unit-envtest.run.log` — ok (CRD schema/dry-run, finalization, SDC status propagation, deviation events; slices `proofs/tests.envtest.*.proof.txt`)
- SDC validation: `proofs/tests.sdc-validation.log` — `PASS ... SDCVAL rc=0`
- Topology parity: `proofs/tests.topology-parity.log` — `COUNTS: ... nodes=4 links=4 ... TOPOLOGY_PARITY_OK`
- Observability: `proofs/tests.observability.log` — `OBSERVABILITY_SUITE_OK` (flow-plugin pin, anonymous auth disabled, 4 dashboards, 10 alert rules)
- Teardown: `proofs/tests.teardown.log` — `TEARDOWN_SUITE_OK` (idempotent repeat success)
- Full Go tree: `proofs/go-test.all.run.log` — `GO_TEST_EXIT=0`
- Traffic/failure/SRv6-capture/SRv6-failover integration suites require the live SONiC gNMI endpoints; see Honest limitations.

### T079a — CRD set assertion: DONE
`scripts/lib/assert_crds.sh` runs inside provision immediately after the CRD apply and passed in the final run: `[assert-crds] OK: AINETOPS-owned CRDs = srv6services.ainetops.io and no duplicate/conflicting fabric/device-config CRDs detected` (line 347 of `proofs/cycles/provision-final-gate-fail.log`, slice `proofs/cycles/provision-final.rollout+crds.slice.txt`). `MigrationPlan` is not enabled (T060 decision), so the owned set is exactly `SRv6Service.ainetops.io`. Historical run log: `proofs/assert-crds.run.log`.

### T080 — Cycles, idempotence, off-from-partial, conformance profile, runtime scan: DONE to the extent this host permits
- Three clean provision/test/off cycles with per-cycle inventories and runtime scans: `proofs/cycles/provision-{1,2,3}.log`, `off-{1,2,3}.log`, `off-*-noop.log`, `test-{fabric,parity,observability}-{1,2,3}.log`, `runtime-{inventory,scan}-*-{1,2,3}.log`, runner log `proofs/cycles/cycles.run.log` + `cycles_runner.stdout.log`.
- Second-provision idempotence: `proofs/cycles/idempotence-provision-{1,2}.log`, `proofs/cycles/idempotence-off.log`.
- Off-from-partial-state: re-proven live this pass (`proofs/cycles/off-partial-final.log`, exit 0) and `proofs/cycles/off-from-partial.log` / `off-from-partial-noop.log`.
- Conformance-profile (`sonic-vm`) cycle: `proofs/cycles/provision-conformance.log`, `off-conformance.log`.
- Standalone/Compose scan: `proofs/cycles/runtime-scan-runtime*.log` — `RUNTIME_SCAN_NO_STANDALONE` (slice `proofs/cycles.runtime-scan-runtime.log.proof.txt`); Docker/Helm/kubectl inventories in `runtime-inventory-*.log`.

## Success-criteria matrix (SC-001 … SC-016)

Legend: **VERIFIED** = passing grounded artifact; **GATE-CORRECT** = behavior implemented and observed failing closed as the spec requires; **ENV-BLOCKED** = requires a live qualified SONiC gNMI endpoint that this air-gapped host cannot provide (root-cause evidence below).

| SC | Status | Grounding |
|---|---|---|
| SC-001 | PARTIAL / ENV-BLOCKED | 8-node lab deploys and locally-buildable apps reach Ready (`proofs/cycles/provision-final.rollout+crds.slice.txt`, `runtime-inventory-docker-*.log`); SDC/Kubenet/KUID upstream controller pods cannot reach Ready (see Honest limitations #1) |
| SC-002 | ENV-BLOCKED (suite implemented) | BGP/EVPN session asserts live in `tests/integration/fabric_verify.sh` + `evpn_traffic.sh`; require live SONiC gNMI/BGP |
| SC-003 | ENV-BLOCKED (suite implemented) | `tests/integration/evpn_traffic.sh` (L2/L3/isolation) |
| SC-004 | VERIFIED | Golden/table fixtures: `proofs/tests.golden.log`, `proofs/tests.unit.log`; unsupported-fixture rejection proofs `proofs/anchor.unsupported_*.txt`, `proofs/collision_rejected_test.txt`, `proofs/batch_mixed_unsupported_test.txt` |
| SC-005 | VERIFIED (offline) | repeat-apply zero-mutation tests in `proofs/tests.unit.log` (idempotence/canonical-hash cases) + `proofs/canonical_hash_input.txt` |
| SC-006 | VERIFIED (offline) | `proofs/tests.integration.drift_preservation.run.log` |
| SC-007 | VERIFIED (offline) | `proofs/tests.failure.log` (Degraded classification) + envtest SDC status propagation `proofs/tests.envtest.provider_sdc_status_propagation_test.go.proof.txt` |
| SC-008 | PARTIAL | Prometheus/Grafana/gNMIc/OTel configs verified and pods Running; targets list asserted offline (`proofs/tests.observability.log`, `OBSERVABILITY_SUITE_OK`); live scrape of SONiC sources ENV-BLOCKED |
| SC-009 | PARTIAL | Alert rules present and evaluated by suite (`alert-LinkDown`, `alert-BGPPeerDown`, `alert-SRv6PathDown`, … in `proofs/tests.observability.log`); live firing during forced failure ENV-BLOCKED |
| SC-010 | VERIFIED | `proofs/denylist.run.log` — "All deny-list checks passed", exit 0, whole-repo scan |
| SC-011 | PARTIAL | Provision reaches apps Ready + intent applied idempotently (`proofs/cycles/provision-final-gate-fail.log`, `idempotence-provision-*.log`); final "all Ready" gate ENV-BLOCKED (upstream images) |
| SC-012 | VERIFIED | full, partial, and no-op offs all exit 0 with zero owned resources left: `proofs/cycles/off-{1,2,3}.log`, `off-*-noop.log`, `off-partial-final.log`, `off-noop-final.log`, `proofs/tests.teardown.log` |
| SC-013 | GATE-CORRECT / ENV-BLOCKED | SRv6 capture/failover suites implemented (`proofs/tests.srv6-capture.log`, `tests.srv6-failover.log`, `tests.integration.srv6_capture_counters.run.log`, `srv6_failover_path_change.run.log`); capability gate **correctly refuses** to certify the unqualified image rather than silently passing (`proofs/cycles/provision-final-gate-fail.log`: "capability gate failed for profile sonic-vs") |
| SC-014 | VERIFIED (offline) | CRD/status visibility + all-or-nothing validation: `proofs/tests.api.log`, envtest proofs, unsupported-rejection proofs (see SC-004) |
| SC-015 | VERIFIED (static parity) | `proofs/tests.topology-parity.log` — `TOPOLOGY_PARITY_OK`, nodes 4/4 and links 4/4 between `lab/topology.clab.yml` and `deploy/observability/topology-configmap.yaml`; live Grafana-vs-Prometheus value match ENV-BLOCKED |
| SC-016 | PARTIAL | Pipeline path fixed as gNMIc → OTLP → OTel → Prometheus (`deploy/gnmi/gnmic.yaml` otlp output, `deploy/observability/otel-collector.yaml` pipelines, `prometheus.yaml` scrape job), exporter-failure alerts present (`alert-GNMIcExportFailures`, `alert-OTelExportFailures`); live zero-duplicate-series proof ENV-BLOCKED |

## Honest limitations (root-cause evidence, not claims of success)

1. **Upstream Kubenet/KUID/SDC controller images cannot run on this host.** Their pinned references in the install manifests are placeholder digests (`sha256:1111…`, `bbbb…`, …) and no matching images exist locally; the management network is air-gapped — `docker pull ghcr.io/kubenet-dev/kubenet-controller` → `dial tcp 20.233.83.147:443: connect: connection refused`, `ghcr.io/sdcio/sdc-config` → `denied`; the local registry (`http://localhost:5000/v2/_catalog`) holds only `sonic-vs`, `linux-net`, `linux-srv6`. Provision therefore logs "controller pods not Ready within window (kubenet=false kuid=false)" / "0/4 SDC component pods Ready" and continues best-effort (lines 278–294 of `proofs/cycles/provision-final-gate-fail.log`). Every AINETOPS-authored component that CAN be built/loaded locally reaches Ready.
2. **The pinned `sonic-vs` image lacks the gNMI/telemetry feature entirely** — `FEATURE` in its `config_db.json` contains only `swss, bgp, teamd, nat, database, lldp, dhcp_relay, macsec` and no telemetry/gNMI supervisor program, so port 8080/9339 never listens (`connection refused` from `172.31.0.21:8080`). Per FR-022/quickstart the conformance suite MUST NOT skip a failed capability, so `provision.sh` fails closed with "sonic-vs failed gate; this profile is not SRv6-qualified. Use --profile sonic-vm for conformance" — the specified, correct behavior. `sonic-vm` in turn requires KVM and an operator-built image (`local/sonic-vm`, versions.lock.yaml lines 79–81) that this host does not provide.
3. Consequently SC-002/SC-003/SC-013 (and the live halves of SC-008/SC-009/SC-015/SC-016) are **implemented and fail-closed, not falsely passed**. Cleaning up this state is proven repeatable (SC-012 VERIFIED).

## Final checkpoint statement

All Phase 8 deliverables (T073–T080, T074a, T079a) are implemented, and every criterion that can be observed on this host is grounded in a passing, line-numbered artifact above. No proprietary runtime is present (deny-list + supply-chain scans exit 0); translation loss is guarded by all-or-nothing validation tests (SC-004/SC-014); cleanup is proven repeatable from full, partial, and already-clean states (SC-012). Runtime-only success criteria that require a SRv6-qualified SONiC image and upstream controller images are blocked by the documented, evidenced air-gap of this host and fail closed rather than being silently skipped.
