# Tasks: agentic-netops on Nokia SR Linux

**Input**: Design documents from `/specs/001-agentic-netops-srlinux-evpn-fabric/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

Phases 1–3 are offline (build, unit tests, static checks); phases 4–6 need the
lab host (Docker, kind, containerlab, an LLM key in `.env`). Every task names
the files it delivers; every phase ends with the commands that prove it.
Evidence for live phases goes under `.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs/`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files)
- **[US1..US4]**: user story from spec.md

---

## Phase 1: Foundation — pins, topology, lifecycle (offline)

**Purpose**: the SR Linux lab definition and the host lifecycle, without a running lab.

- [ ] T001 [US1] Pin SR Linux in `versions.lock.yaml`: replace `sonic_images:` with `srlinux_images.srlinux: {image: ghcr.io/nokia/srlinux:26.7.2@sha256:0096fe3ebcafabb7253492e2060425fe027a168e0e066766d1e85efbb0b48be8, digest, tag, notes}`, replace `sonic_yang:` with `srlinux_yang: {release: v26.7.2, model_repo: https://github.com/nokia/srlinux-yang-models, notes}`, keep every other pin; `scripts/lib/verify_pins.sh` validates the new sections and no `sonic` key remains.
- [ ] T002 [US1] Rewrite `lab/topology.clab.yml` per `contracts/lab-topology.md`: kind `nokia_srlinux` (`image` digest-pinned, `type: ixrd2l`), four fabric nodes with `startup-config: profiles/srlinux/config/<node>.cfg`, same mgmt IPs, links on `e1-1..e1-4`, clients unchanged; remove the SONiC named volumes.
- [ ] T003 [P] [US1] Write startup configs `lab/profiles/srlinux/config/spine01.cfg`, `spine02.cfg`, `leaf01.cfg`, `leaf02.cfg` (SR Linux CLI `set` syntax) implementing research D4: interfaces/subinterfaces with the /31 + /127 addressing, system0, default NI, eBGP underlay (AS 65000/65101/65102), iBGP EVPN overlay AS 65535 with spine route reflectors, export policy for loopbacks, gNMI server on mgmt :57400 with `tls-profile clab-profile`; leaves add mac-vrf `vlan100` (evi/L2VNI 100, `vxlan1.100`, `ethernet-1/3.0` untagged) and ip-vrf `VrfBlue` (evi/L3VNI 2000, `vxlan1.2000`, `lo0.2000` 192.168.201.1/32 on leaf01, 192.168.202.1/32 on leaf02).
- [ ] T004 [P] [US1] Replace `lab/profiles/sonic-vs/` and `lab/profiles/sonic-vm/` with `lab/profiles/srlinux/profile.yaml` (profile name, image, `bootstrap.path`, notes on credentials/TLS/persistence) and `lab/profiles/srlinux/bootstrap/README.md`; delete `lab/images/sonic-vs-gnmi/`, `scripts/build-sonic-vs.sh` and `lab/bootstrap/README.md` SONiC content (rewrite it for SR Linux).
- [ ] T005 [US1] `scripts/lib/containerlab.sh`: `deploy` no longer kicks supervisord; `bootstrap <profile>` waits for gNMI Capabilities on every node (`gnmic --address <ip>:57400 --tls-ca lab/clab-agentic-netops-fabric/.tls/ca/ca.pem -u admin -p "$SRL_DEFAULT_PASS"` read from env `SRLINUX_ADMIN_PASSWORD`, default `NokiaSrl1!`, never written to disk), creates user `agentic` (password from `gnmi-lab-creds`) via one gNMI Set on `/system/aaa/authentication/user[username=agentic]`, then publishes the containerlab CA into Secret `gnmi-lab-tls` key `ca.crt` (patch the existing Secret); `destroy` drops the SONiC volume logic. Keep the idempotent marker semantics (a node already carrying the user is skipped).
- [ ] T006 [P] [US1] `scripts/lib/lab_secrets.sh`: materialise `./secrets/ca.crt` from `gnmi-lab-tls` (`tls.crt`/`tls.key` optional), export `GNMI_USER`/`GNMI_PASS`; `scripts/lib/preflight.sh`: drop the KVM/sonic-vm check, keep pins/tool checks, profile default `srlinux`.
- [ ] T007 [P] [US1] `scripts/lib/qualify.sh` per research D8: run `tests/integration/srlinux_gnmi_suite.sh` (`Capabilities`, `Get`, `Set`, `Subscribe`), `scripts/lib/persistence.sh --run`, then `tests/integration/evpn_suite.sh` (`EVPN-Type2`, `EVPN-Type3`, `EVPN-Type5`, `Remote-VTEP`, `Overlay-Traffic`) and `yang_paths_suite.sh`; SRv6 entries recorded as `not-applicable` with the reason; report JSON shape unchanged.
- [ ] T008 [US1] Write `tests/integration/srlinux_gnmi_suite.sh` (Capabilities asserts `srl_nokia-*` models and gNMI version; Get asserts `/system/information/version` content; Set writes a witness on `/system/information/contact`, reads it back, deletes it; Subscribe streams one `/interface[name=ethernet-1/1]/statistics` sample) and rewrite `scripts/lib/persistence.sh` (witness leaf, `docker restart` each node, wait for gNMI, re-read).
- [ ] T009 [US1] Rewrite `tests/integration/fabric_verify.sh`: BGP sessions Established on all nodes via gNMI Get `/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state`; EVPN AF negotiated; Type-2/3/5 presence from `/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post/{mac-ip-routes,imet-routes,ip-prefix-routes}`; remote VTEP ≥1 on `vxlan1.100` multicast-destinations; client01↔client02 ping; loopback IPv6 reachability between leaves; no tenant NI/VXLAN on spines (`/network-instance` list has only `default` and `mgmt`; no `/tunnel-interface`).
- [ ] T010 [P] [US1] Replace `tests/integration/evpn_srv6_suite.sh` with `tests/integration/evpn_suite.sh` (the EVPN checks above as `--run <name>` entries plus overlay traffic), rewrite `yang_paths_suite.sh` + `lab/requirements/yang-paths.txt` for SR Linux paths (`/interface`, `/network-instance`, `/tunnel-interface`, `/acl`, `/system/gnmi-server`), rewrite `mtu_ecmp.sh`, `evpn_traffic.sh`, `topology_parity.sh`, `drift_preservation.sh`, `idempotence.sh`, `update_delete_survivability.sh`, `failure_recovery_invalid_yang.sh`, `teardown_suite.sh`, `cycles_runner.sh` to SR Linux (gNMI or `sr_cli` read-only); delete `srv6_capture_counters.sh` and `srv6_failover_path_change.sh` (SRv6 out of scope, recorded in `scripts/ci/run_suites.sh`).
- [ ] T011 [US1] `scripts/provision.sh` + `scripts/off.sh` + `scripts/install-deps.sh`: profile flag `--profile srlinux`, build `cmd/srlinux-provider` to image `agentic-netops-srlinux-provider:dev`, apply `deploy/agentic-netops/manifests/provider.yaml`, start the executor with `FABRIC_NODE_MAP='{"leaf01":"172.31.0.21:57400","leaf02":"172.31.0.22:57400","spine01":"172.31.0.11:57400","spine02":"172.31.0.12:57400","site-a":"172.31.0.21:57400","site-b":"172.31.0.22:57400"}'`, `FABRIC_GNMI_USER/PASS` from `gnmi-lab-creds`, `FABRIC_GNMI_CA=./secrets/ca.crt`; compat-pins ConfigMap keys per data-model.md with `cap-sai-srv6: "false"`; `install-deps.sh` pulls `ghcr.io/nokia/srlinux` and drops the SONiC image/YANG resolution; `off.sh` unchanged except volume cleanup.
- [ ] T012 [P] [US1] Invert the supply-chain policy in `scripts/ci/supply_chain.sh` (forbid `\bsonic\b|sonic-vs|sonic-net|sonic_yang` in `go.mod go.sum cmd config deploy lab`), update `docs/SUPPLY_CHAIN.md`, `Makefile` (`test-static` checks the SR Linux image, `build` builds `cmd/srlinux-provider`, `lab-qualify` unchanged), `scripts/ci/sonic_image_feature_audit.sh` → deleted, `scripts/ci/run_suites.sh` suite list updated, `.github/workflows/ci.yaml` unchanged in shape.

**Checkpoint**: `bash -n` on every script, `yq e . lab/topology.clab.yml`, `./scripts/lib/verify_pins.sh`, `scripts/ci/supply_chain.sh` (SONiC absence check passes on the tree), `grep -ri sonic lab scripts tests` returns nothing but the legacy notes.

---

## Phase 2: Southbound — renderer, executor, provider (offline)

**Purpose**: the intent-to-device path speaks SR Linux over gNMI and is unit-tested.

- [ ] T013 [US2] `pkg/fabricplan/plan.go`: types per data-model.md (`Op{GNMI}`, `GNMISet`, `GNMIUpdate`, `Check{Type,Path,Expect,MinCount}`); keep `PortMapper`, `Options` (+ `VXLANTunnel` default `vxlan1`, `SystemIPv4` unused), `L3VLANForVNI`, `DeviceVRFName`, `DeviceACLTableName`, refusal messages.
- [ ] T014 [US2] Render `vlan` and `mac-vrf` in `pkg/fabricplan/plan.go` exactly as `contracts/srlinux-render-contract.md` (subinterface, vxlan-interface, NI with bgp-evpn/bgp-vpn, RT normalisation `target:`, RD omission, checks incl. multicast-destinations `gnmi-list-min`, rollback deletes).
- [ ] T015 [US2] Render `ip-vrf` and IRB in `pkg/fabricplan/plan.go` (routed subinterface tagged `L3VLANForVNI`, `vxlan1.<l3vni>` routed, ip-vrf NI, Type-5 `gnmi-contains` check, irb0 subinterface with anycast-gw).
- [ ] T016 [US2] Render `acl` in `pkg/fabricplan/plan.go` (`/acl/acl-filter` entries with match/action, default entry, input/output binding on the Network's subinterfaces or index 0 for acl-only, checks, rollback); `pkg/migration/acl.go` name derivation unchanged.
- [ ] T017 [US2] Tests: rewrite `pkg/fabricplan/plan_test.go` and add `tests/unit/fabricplan_golden_test.go` with golden JSON plans for the five constructs under `tests/unit/testdata/fabricplan/`; cover RT normalisation, RD omission, EVI=VNI, band refusals, unknown port refusal.
- [ ] T018 [US2] `pkg/register/oc_vs_srlinux.yaml` (replace `oc_vs_sonic.yaml`): every path family the renderer emits (`/interface`, `/interface/subinterface`, `/tunnel-interface/vxlan-interface`, `/network-instance`, `.../protocols/bgp-evpn`, `.../protocols/bgp-vpn`, `/acl/acl-filter`, `/system/aaa`) with `prefer: srlinux` and the OpenConfig equivalent noted; update `tests/unit/register_guard_test.go` and `render_register_positive_test.go` so `make verify-register` passes against the new renderer.
- [ ] T019 [US2] `cmd/fabric-executor/main.go`: gNMI backend per `contracts/fabric-executor-api.md` — vendored `github.com/openconfig/gnmi` + `google.golang.org/grpc` (`go mod tidy && go mod vendor`; pin versions in `versions.lock.yaml` `go_modules:`), TLS with CA file, username/password metadata, Set per op, save after success, Get-based verify types; remove every docker API line; keep `/v1/nodes` and node-map normalisation.
- [ ] T020 [P] [US2] Rename `controllers/sonicprovider` → `controllers/srlprovider` and `cmd/sonic-provider` → `cmd/srlinux-provider` (package `srlprovider`, metric subsystem `srlprovider`, leader election id `agentic-netops-srlinux-provider`, field manager `agentic-netops-srlinux-provider`); update imports in `tests/envtest/*.go`, `README-CONTROLLERS.md`, `Makefile`, `docker/` and `docs/`.
- [ ] T021 [US2] `controllers/srlprovider/network_controller.go`: unchanged loop; Options carry `VXLANTunnel: "vxlan1"`; error text mentions gNMI; `pkg/compat/{compat.go,matrix.go,pins.go}`: pins `srlinux-image`/`srlinux-yang`, `Validate` requires SRv6 only when `mappingRequiresSRv6` is asked by the SRv6Service controller (Networks pass with `cap-sai-srv6=false`); update `tests/unit/compat_fullvalidate_test.go`.
- [ ] T022 [P] [US2] `deploy/agentic-netops/manifests/provider.yaml`, `config/rbac/*.yaml`, `deploy/rbac/{base,controller-rbac,secret-generator-job}.yaml`: provider names, `FABRIC_PORT_MAP='{"wan1":"ethernet-1/4","ethernet1":"ethernet-1/3","ethernet2":"ethernet-1/3","ethernet3":"ethernet-1/3","e1-1":"ethernet-1/1","e1-2":"ethernet-1/2","e1-3":"ethernet-1/3","e1-4":"ethernet-1/4"}'`, `allow-fabric-gnmi-egress` to `172.31.0.0/16` port 57400.
- [ ] T023 [P] [US2] `cmd/intent-translator/main.go` and `pkg/migration/site.go`: site inventory text names SR Linux ports (`ethernet-1/3`, `ethernet-1/4`) in refusals; no behaviour change.
- [ ] T024 [US2] `pkg/render/*` and `api/v1alpha1/srv6service_types.go` docs: SRv6Service reconciles to `Ready=False` `CapabilityMissing` on this site (controller unchanged, comments updated); `config/samples/agentic-netops_v1alpha1_srv6service.yaml` keeps applying and `provision.sh` no longer waits for it.

**Checkpoint**: `go build -mod=vendor ./... && go build -mod=vendor -tags agentic_netops_k8s ./cmd/... ./controllers/... && go vet -mod=vendor -tags agentic_netops_k8s ./cmd/fabric-executor ./controllers/... && go test -mod=vendor ./tests/unit ./pkg/... && make verify-register && grep -rn "docker" cmd/fabric-executor/main.go` returns nothing.

---

## Phase 3: Platform surfaces — telemetry, manifests, agents, UI, docs, video driver (offline)

- [ ] T025 [US3] `deploy/gnmi/gnmic.yaml` per `contracts/telemetry.md` (targets :57400, subscriptions, prom output, TLS CA only); `deploy/gnmi/README.md`, `apply-job.sh`, `apply-job-all.sh`, `gnmi-incluster-job-all.yaml` updated to SR Linux paths.
- [ ] T026 [US3] Dashboards `deploy/observability/dashboards/physical-fabric.json` (interface counters/oper-state/BGP state per node from the new series), `sdc-orchestration.json` (wording), `srv6-service-path.json` (panels marked not applicable on SR Linux); `deploy/observability/{prometheus.yaml,otel-collector.yaml,grafana.yaml,topology-configmap.yaml,rules/agentic-netops.rules.yaml,metrics-inventory.md,README.md,tests/no-duplicate-series.md}` and `scripts/observability/gen-topology-configmap.sh` updated to the SR Linux series and node metadata.
- [ ] T027 [P] [US1] `deploy/sdc/seed/srlinux-schema.yaml` (replaces `sonic-schema.yaml`: Schema `srlinux` `spec.repositories` pointing at `nokia/srlinux-yang-models` `v26.7.2`, connection profile gNMI 57400 JSON_IETF TLS, sync profile unchanged), `deploy/sdc/seed/discovery-rule.yaml`, `deploy/sdc/README.md`; `deploy/kubenet/**` (`topology.yaml` provider labels, `crds`, `tests/negative.yaml`, `README.md`) wording.
- [ ] T028 [P] [US2] `deploy/agents/{namespace-rbac,telemetry,deployer}.yaml`, `deploy/agents/README.md`, `deploy/agents/tests/probes/mgmt-network-denial.sh` and `deploy/tests/probes/separation.sh`: probe gNMI 57400 instead of 8080; provider names.
- [ ] T029 [P] [US2] Agents: `agents/config/config.py` comment on `KUID_L3VNI_MAX` (SR Linux: ip-vrf attachment subinterface tag derived from the L3VNI), `agents/supervisors/provisioning/graph/graph.py` ("SR Linux EVPN/VXLAN fabric"), `agents/provisioning/deployer/tools/deployer_tools.py` docstring (`controllers/srlprovider`), `agents/README.md`; `uv run ruff check .` and `uv run pytest` pass in `agents/`.
- [ ] T030 [P] [US2] UI: `ui/src/components/MainArea/MainArea.tsx` node label "SR Linux fabric"; `npm run typecheck && npm run build` pass in `ui/`.
- [ ] T031 [US1] `README.md`: badges (SR Linux 26.7.2, containerlab nokia_srlinux), the lab section, the "What you get" table, quickstart (`--profile srlinux`), known limitations (SRv6 not applicable; acl-only binding on subinterface 0), repository layout; the Demo section keeps the video element and states the recording is produced by Phase 6 (placeholder asset URL replaced when the take is accepted).
- [ ] T032 [P] [US1] `TUTORIAL.md`: SR Linux proofs (`sr_cli` show commands), bootstrap description (startup-config, no self-repair hooks needed), intent walkthrough unchanged.
- [ ] T033 [P] [US1] Docs: rewrite `docs/DEPENDENCIES.md`, `docs/OPERATORS.md`, `docs/OPERATIONS.md`, `docs/DEVELOPERS.md`, `docs/README-OPERATORS-DEVELOPERS.md`, `docs/INTENT_TIER_SERVICE_TYPES.md` (render table for SR Linux), `docs/INTENT_TIER_RUNBOOK.md`, `docs/SECURITY_AUDIT.md` (gNMI creds/TLS), `deploy/observability/README.md`; move SONiC-only findings (`SONIC_IMAGE_SWAP_ANALYSIS.md`, `SRV6_GNMI_CAPABILITY_FINDINGS.md`, `FABRIC_BGP_EVPN_DEFERRED.md`, `CLUSTER_REBUILD_FINDINGS.md`, `PHASE8_UNBLOCK_STATUS.md`, `SUGGESTED_PROMPTS_POSTMORTEM.md`) under `docs/legacy/sonic/` with a one-paragraph index `docs/legacy/README.md`.
- [ ] T034 [P] [US1] `docs/images/lab-topology.svg`: node labels "SR Linux" and port names `e1-1..e1-4`; regenerate `docs/images/lab-topology.png` when `rsvg-convert` or `inkscape` is available (otherwise leave the PNG and note it in `docs/images/README.md`).
- [ ] T035 [US4] `testautomation/video/record.py` per research D10: router proofs via `docker exec <leaf> sr_cli "<show>"`, pre-snapshot via `sr_cli "show network-instance summary"`, identifiers logic unchanged, prompt list unchanged; `testautomation/video/accept.py` and `check_framing.py` adjusted to the new proof strings; `docs/DEMO_VIDEO_PROMPT.md` and `docs/DEMO_VIDEO_RETAKE.md` rewritten for SR Linux (validation commands, ground-truth appendix template).
- [ ] T036 [P] [US1] `docs/HOST_RUNBOOK_WIGGUM_OPUS5.md`: how to run phases 4–6 on the host with wiggum (`WIGGUM_PROPOSER=claude ANTHROPIC_MODEL=claude-opus-5 ./scripts/run-loop.sh`), the `.env` requirement, the site ground-truth checklist to refresh before the take, and the acceptance report format; `scripts/run-loop.sh` `FEATURE=001-agentic-netops-srlinux-evpn-fabric`.
- [ ] T037 [P] [US1] `scripts/bootstrap-srlinux-repo.sh`: creates `mairp/agentic-netops-srlinux` (public, Apache-2.0 description) with `gh repo create` if absent, pushes the current tree as `main`, sets the description/topics; idempotent and dry-run capable.
- [ ] T038 [US1] Sweep: `grep -rniE "sonic|redis-cli|vtysh|config_db" --exclude-dir=vendor --exclude-dir=.git --exclude-dir=legacy .` lists only intentional mentions (history notes, the supply-chain deny pattern, `docs/legacy/`); record the list in `docs/MIGRATION_FROM_SONIC.md` together with the mapping table SONiC mechanism → SR Linux mechanism.

**Checkpoint**: `make verify-pins`, `bash scripts/ci/supply_chain.sh`, `python3 -m py_compile testautomation/video/*.py`, agents `uv run ruff check . && uv run pytest`, ui `npm run build`, `go test -mod=vendor ./tests/unit ./pkg/...`.

---

## Phase 4: Bring-up on the host (live) [US1]

- [ ] T039 [US1] `./scripts/install-deps.sh` and `docker pull ghcr.io/nokia/srlinux:26.7.2`; record `docker images --digests | grep srlinux` in `gates/proofs/srlinux-image.txt`.
- [ ] T040 [US1] `./scripts/provision.sh --profile srlinux --cluster-name agentic-netops` exits 0; keep `provision.log` under `gates/proofs/`; fix and re-run anything the live image rejects (startup-config syntax, gNMI paths, save command — each fix lands in the tree files of Phase 1/2, never as manual node changes).
- [ ] T041 [US1] `make lab-qualify` prints `[qualify] OK`; `gates/proofs/qualify.report.json` shows every gNMI/EVPN test `pass` and SRv6 entries `not-applicable`.
- [ ] T042 [US1] `./tests/integration/fabric_verify.sh run` exits 0 with all assertion lines passed; output saved to `gates/proofs/fabric-verify.log`.
- [ ] T043 [US1] Persistence: `docker restart clab-agentic-netops-fabric-leaf01`, wait, `fabric_verify.sh` passes again; log saved.
- [ ] T044 [US3] Telemetry: `kubectl -n agentic-netops-system port-forward svc/gnmic 9273` and `curl :9273/metrics | grep -c interface_statistics` > 0 for four sources; Grafana "Fabric telemetry" screenshot saved to `docs/images/grafana-fabric-telemetry.png` (replace) and `docs/images/grafana-physical-fabric.png`.

**Checkpoint**: proofs listed above exist and are referenced from `GATE4-EVIDENCE.md`.

---

## Phase 5: Intent tier convergence on the host (live) [US2]

- [ ] T045 [US2] `./scripts/provision.sh --profile srlinux --cluster-name agentic-netops --with-intent-tier` with a valid `.env`; all six tier deployments Ready; UI on :30000 healthy.
- [ ] T046 [US2] vlan: prompt `Provision a vlan 131 on leaf01 ethernet1 for tenant acme` through the console (or `agents/tests/e2e` driver), two confirmations, `Network` `Ready=True/ApplySucceeded`; save `kubectl get network -o json` and `sr_cli "show network-instance vlan-131 interfaces"` under `gates/proofs/construct-vlan/`.
- [ ] T047 [US2] ip-vrf: `Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.51.0.0/24` → Ready=True; proofs: NI summary, route-table, EVPN RT5 on the peer leaf.
- [ ] T048 [US2] mac-vrf: `Extend vlan151 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue` → Ready=True; proofs on both leaves incl. multicast-destinations (remote VTEP).
- [ ] T049 [US2] acl: `Apply an acl on leaf02 wan1 for tenant acme: allow ingress tcp port 443 from 10.0.0.0/24, deny everything else` → Ready=True; proofs: `show acl acl-filter`, binding on the subinterface.
- [ ] T050 [US2] Drift repair: delete the vlan NI on leaf01 with `sr_cli` (the only sanctioned write outside the executor, for this test), wait one resync (≤5 min), `Ready` returns True with an `ApplySucceeded` event; log saved.
- [ ] T051 [US2] Refusal: `Provision a vlan 132 on leaf01 ethernet9 for tenant acme` is refused by the translator naming the site's ports; supervisor audit line saved.
- [ ] T052 [US2] Update `README.md` "What works" paragraph and `docs/INTENT_TIER_SERVICE_TYPES.md` with the dates and measured Enter-to-Deployed seconds.

**Checkpoint**: four `Ready=True` Networks with proofs; `GATE5-EVIDENCE.md` cites them.

---

## Phase 6: Walkthrough recording (live) [US4]

- [ ] T053 [US4] Refresh the site ground truth in `docs/DEMO_VIDEO_PROMPT.md` (free identifiers, existing Networks, `sr_cli` syntax verified on the image) and pick the identifiers for the take (single-use).
- [ ] T054 [US4] `cd testautomation/video && python record.py --smoke --take smoke` exits 0 with `commands without a returned prompt: none`.
- [ ] T055 [US4] Rehearsal (no video) with the primed identifiers; per-prompt Enter-to-Deployed seconds recorded; any refusal fixed in the tree, never by rewording outside the sanctioned list.
- [ ] T056 [US4] Final take: `record.py --prompts A,B,C1 --take final` (fresh identifiers) ends with `DONE take=final prompts=3`; `final.mp4` is the only `.mp4`.
- [ ] T057 [US4] `python accept.py --take final` prints no `FAIL`; `evidence.json` has `accept_pass: true`; copy it to `docs/media/agentic-netops-srlinux-intent-tier-demo-evidence.json`.
- [ ] T058 [US4] Publish: upload `final.mp4` as a GitHub asset on the repository (README video element URL), commit the evidence JSON and the refreshed screenshots; `README.md` Demo section describes the SR Linux take.

**Checkpoint**: `final.mp4` accepted and linked from the README; `GATE6-EVIDENCE.md` cites `evidence.json`.

---

## Dependency order

Phase 1 → 2 → 3 (offline; 1 and 2 can overlap on disjoint files) → 4 → 5 → 6.

## Definition of done

All checkpoints green, `docs/HOST_RUNBOOK_WIGGUM_OPUS5.md` followed end to end on the host, `final.mp4` accepted, and no SONiC artifact left outside `docs/legacy/` and the supply-chain deny pattern.
