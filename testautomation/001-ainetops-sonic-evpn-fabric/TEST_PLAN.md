<!-- wiggum-verification-plan content-hash: 2dc3dfb091ab087ba0a8060b94955682356ee0e3f086578fd31fbf6e02ec6307 -->
# Verification and Test Automation Plan

## Provenance

- Plan ID: `verification-85ce0e584936afa1b033`
- Plan content hash: `2dc3dfb091ab087ba0a8060b94955682356ee0e3f086578fd31fbf6e02ec6307`
- Source bundle ID: `0H2WFJJVJMN8Q6PNK86K5PWX63`
- Source semantic hash: `9014e546c2a1b5e9a98e448a762a886890e87f6daf2fa25c78942abcf314e137`
- Source specification: `/root/ainetops-demo/specs/001-ainetops-sonic-evpn-fabric/tasks.md`
- Absolute workdir: `/root/ainetops-demo`
- Project fingerprint: `2b4fa73ba9fc5f595ac9a1cfcd7dd362bbfb98360c441e3c1b0228af0c333dfe`

## Coverage obligations

| ID | Outcome | Level | Kind | Automation | Phase |
| --- | --- | --- | --- | --- | --- |
| VO-ce3eeca45cee3d91adc3 | T001 Create the implementation directory structure from [plan.md](./plan.md), including | integration | effect-witness | planned | 1 |
| VO-e944d3dcd900a11e2316 | T002 Research and select one mutually compatible Kind binary/node image, Kubernetes, | contract | positive | planned | 1 |
| VO-c3ccb4b278c1b45cd324 | T003 Select and record a pinned containerlab version and both SONiC profile image | contract | positive | planned | 1 |
| VO-abf8ebaaa7255ba4ad27 | T004 Select the SONiC/OpenConfig YANG schema commit and record its compatibility with | integration | effect-witness | planned | 1 |
| VO-96ef82c55c68e552f180 | T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, the Grafana Flow plugin, and | contract | positive | planned | 1 |
| VO-3feec31435627faace32 | T006 Implement `make verify-pins` to reject `latest`, floating refs, missing digests, and | contract | positive | planned | 1 |
| VO-8d0a38415c635e27b426 | T007 Implement reusable strict-shell preflight for host resources, Kind/runtime | contract | positive | planned | 1 |
| VO-4885269c94eff786a609 | T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side | contract | positive | planned | 1 |
| VO-c78953b4d417217fed57 | T009 [US3] Author `lab/topology.clab.yml` with `spine01`, `spine02`, `leaf01`, `leaf02`, | contract | positive | planned | 2 |
| VO-7da9012ea73d9d3536fa | T010 [P] [US3] Create the `sonic-vs` profile with bootstrap limited to management, TLS, | integration | effect-witness | planned | 2 |
| VO-14f31bd9bedd3b3ea644 | T011 [P] [US3] Create the `sonic-vm` conformance overlay and document KVM/nested | integration | effect-witness | planned | 2 |
| VO-0bcc810efc91a86a5bc6 | T012 [P] [US3] Create Linux endpoint images/configuration and deterministic dual-stack | integration | effect-witness | planned | 2 |
| VO-a7528052c383abd6cde2 | T013 [US3] Implement SONiC gNMI Capabilities/Get/Set/Subscribe qualification tests | contract | positive | planned | 2 |
| VO-f4bb60a37a4e6baaefe5 | T014 [P] [US3] Implement persistent configuration and required OpenConfig/SONiC YANG path | contract | positive | planned | 2 |
| VO-d785ed167f6cbab38578 | T015 [P] [US3] Implement BGP EVPN/VXLAN Type 2/3/5 and SRv6 IPv6-underlay, | contract | positive | planned | 2 |
| VO-7fd7d1b1df3650feb53f | T016 [US3] Implement `make lab-qualify` so any failed capability blocks downstream tests | contract | positive | planned | 2 |
| VO-639013e823d2ed354a41 | T017 [US3] Implement idempotent containerlab deploy/inspect/destroy script phases callable | integration | effect-witness | planned | 2 |
| VO-9cb4228df5a48b280af5 | T018 Author `config/kind/cluster.yaml` and idempotent Kind create/delete phases with a | integration | effect-witness | planned | 3 |
| VO-1bc8e079b300f3ec5137 | T019 Implement creation/ownership labeling of the dedicated Docker management network, | contract | positive | planned | 3 |
| VO-a0bda2a4c9cebe5d95d8 | T020 Install pinned Kubenet/KUID CRDs/controllers inside Kind and wait for current- | integration | effect-witness | planned | 3 |
| VO-4ac10627145b0a29fd29 | T021 Install pinned SDC CRDs and schema/config/data/cache components inside Kind with | integration | effect-witness | planned | 3 |
| VO-478311ea3158a0b5a823 | T022 [P] Create least-privilege namespaces, service accounts, RBAC, network policies, and | integration | effect-witness | planned | 3 |
| VO-444acd0a2f7813635692 | T023 Author the Kind deployment manifests/Helm values for the later AINETOPS provider and | contract | positive | planned | 3 |
| VO-3333241ad1182936b859 | T024 Create the exact pinned SONiC `Schema`, connection profile, sync profile, and | integration | effect-witness | planned | 3 |
| VO-bd3f1134f14130aceb96 | T025 Create topology, IP/ASN/ID indices, claims/pools, and fabric design manifests using | integration | effect-witness | planned | 3 |
| VO-10f2a5aa71975c3cabf8 | T026 Scaffold the Go provider manager (`cmd/sonic-provider/`, `controllers/sonicprovider/`) | contract | positive | planned | 4 |
| VO-7e4ee3276177948f78cc | T026a Scaffold the SRv6 service controller binary and reconciler | contract | positive | planned | 4 |
| VO-3e07612674de5f55b15e | T027 Define canonical internal structs for interfaces, loopbacks, BGP, network instances, | contract | positive | planned | 4 |
| VO-7ba202b6c49f1af461c6 | T027a Author the required `SRv6Service.ainetops.io/v1alpha1` CRD and scaffolding: | contract | positive | planned | 4 |
| VO-e067e5b1b7f1100f2215 | T028 [P] Implement `NetworkDevice` selection, dependency watches/indexes, current- | contract | positive | planned | 4 |
| VO-81cafc295ba509e54496 | T029 [P] Implement compatibility-set validation for image, schema, mapping, and upstream | contract | positive | planned | 4 |
| VO-5fd97f54267183f9af95 | T029a Produce a per-path OpenConfig-vs-SONiC-native register for all rendered YANG paths; | contract | positive | planned | 4 |
| VO-8fe4127df0df70b7a2da | T030 Implement abstract-model normalization and reject incomplete, unknown, or conflicting | contract | positive | planned | 4 |
| VO-b54d9d3f750b82a40209 | T031 [P] Implement qualified interface/loopback/MTU and dual-stack IPv4 `/31` plus IPv6 | contract | positive | planned | 4 |
| VO-07f8b27c60dba9c452a3 | T032 [P] Implement qualified BGP global/neighbor and EVPN address-family renderers | contract | positive | planned | 4 |
| VO-75e7fe520580a1631a50 | T033 [P] Implement VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers | contract | positive | planned | 4 |
| VO-86a4a499ca09141db17a | T034 [P] Implement VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, | contract | positive | planned | 4 |
| VO-60ffdbcba9de3de06741 | T035 Compose deterministic ordered output, stable generated names, canonical hashes, | contract | positive | planned | 4 |
| VO-fbfb46e286d5206e3cb1 | T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails | contract | positive | planned | 4 |
| VO-354b299fea44e3cf4b09 | T037 Implement server-side apply with a dedicated field manager, explicit priority, | contract | positive | planned | 4 |
| VO-7145be4f9c20f3ea9cb5 | T038 Observe SDC Config/Target/Deviation status and propagate standard per-device and | contract | positive | planned | 4 |
| VO-1c9e4040526c3bf3973f | T039 Implement bounded backoff/jitter and terminal-vs-transient error classification | contract | positive | planned | 4 |
| VO-9e7799dbe7c60b153a3c | T040 Implement ordered finalization: delete owned SDC intent, confirm/timeout, release | integration | effect-witness | planned | 4 |
| VO-bfe6eb5c31630753e605 | T041 Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, | contract | positive | planned | 4 |
| VO-f4406e3b365b81b0356c | T041a Build the T026a SRv6 service controller binary, load it, and deploy it inside Kind | integration | effect-witness | planned | 5 |
| VO-a1a34cfefd73bd2714bc | T042 [US3] Apply the default Kubenet Network and reconcile dual-stack routed leaf-spine | contract | positive | planned | 5 |
| VO-6af57051fa79a545caea | T043 [US3] Add verification for all expected underlay/EVPN sessions, loopback reachability, | contract | positive | planned | 5 |
| VO-e9e2b214c5b8b533b867 | T044 [P] [US1] Add a bridged L2 tenant example with two cross-leaf attachments, VLAN, | contract | positive | planned | 5 |
| VO-2a596388791ba51056f0 | T045 [P] [US1] Add a routed L3 tenant example with VRF, L3VNI, RD/RT, prefixes, and Type-5 | contract | positive | planned | 5 |
| VO-36cc3e7485520b2d17ff | T046 [P] [US1] Add a symmetric-IRB example with L2/L3 VNIs, gateway addresses, and two | contract | positive | planned | 5 |
| VO-2a21fb268248d2cf735b | T047 [US3] Implement EVPN client traffic tests: cross-leaf L2 reachability, intra-VRF L3/IRB, | contract | positive | planned | 5 |
| VO-8f111b83f1f0b3ea564b | T047a [US3] Implement MTU and ECMP tests: verify maximum effective MTU accommodates VXLAN overhead | contract | positive | planned | 5 |
| VO-d300c6db6ce06dfd276a | T047b [US5] Implement SRv6 capture and counter tests between dedicated clients: capture | contract | positive | planned | 5 |
| VO-24f6b0303f5fe8d755f1 | T047c [US5] Implement failover and operator-directed path-change tests: force primary failure, | contract | positive | planned | 5 |
| VO-817efa5a288ee6449f98 | T048 [US2] Add repeat-apply proof: unchanged intent produces zero SDC spec writes and zero | contract | positive | planned | 5 |
| VO-7fec1413d8abcfcf6487 | T049 [US2] Add partial target failure/recovery, provider restart mid-transaction, and | contract | positive | planned | 5 |
| VO-6e31c53f7ce1891d7fe7 | T050 [US2] Add managed-path drift restoration and unmanaged-path preservation tests | contract | positive | planned | 5 |
| VO-1dbb24e8c9b928f5f3ae | T051 [US2] Add update and delete tests proving shared fabric state and unrelated claims | integration | effect-witness | planned | 5 |
| VO-402dd008e37d1e159e78 | T052 Define a strict normalized input schema for service ID, type, tenant, endpoints, | contract | positive | planned | 6 |
| VO-bb9db15d763b6b8adc66 | T053 [P] [US1] Implement VPLS/multipoint-L2VPN to bridge/L2VNI translation | contract | positive | planned | 6 |
| VO-5c49289faeea3172565e | T054 [P] [US1] Implement L3VPN to VRF/L3VNI/RD/RT/Type-5 translation | contract | positive | planned | 6 |
| VO-6f7a083706d4fa31e390 | T055 [P] [US1] Implement VPWS/E-Line to two-attachment L2VNI with explicit limited- | contract | positive | planned | 6 |
| VO-e655a78b0123af5832f8 | T056 [P] [US1] Implement integrated L2/L3 to symmetric-IRB translation | contract | positive | planned | 6 |
| VO-688be61eb6478483cb2d | T057 [US1] Implement all-or-nothing validation and structured unsupported-feature results | contract | positive | planned | 6 |
| VO-c8a6c5410985a7c8fba9 | T058 Add deterministic CLI/library output with stable provenance annotations on generated | contract | positive | planned | 6 |
| VO-fe56d3af6e7b8b9a8b6a | T058a Package the migration translator as a deterministic library plus CLI binary | contract | positive | planned | 6 |
| VO-87da5ecb90151b7789a4 | T059 Add table/golden tests for every supported, limited, unsupported, collision, and | contract | positive | planned | 6 |
| VO-df1c6a2302947c1b7b7d | T060 Decide from workflow evidence whether annotations/Git review meet audit needs; only | contract | positive | planned | 6 |
| VO-b351881d6e891c68fdcb | T061 If T060 enables the CRD, add structural/CEL validation, status subresource, RBAC, | contract | positive | planned | 6 |
| VO-998fdb1264aab3501a2e | T062 Inventory metrics available from the pinned SONiC schema, SDC, provider, Kubernetes, | contract | positive | planned | 7 |
| VO-44680e3e69a337508ca2 | T063 Deploy gNMIc inside Kind as the sole SONiC device-metric collector, export OTLP to | integration | effect-witness | planned | 7 |
| VO-3a08068ff740db6052ca | T064 [P] Deploy OTel Collector inside Kind with receivers, Kubernetes enrichment, | integration | effect-witness | planned | 7 |
| VO-4960973806850b426b40 | T065 [P] Deploy Prometheus and required operator resources inside Kind with a PVC, pinned | integration | effect-witness | planned | 7 |
| VO-5f1a6a50e73d4bfa93a7 | T066 [P] Deploy Grafana inside Kind with a PVC where required, Secret-based credentials, | integration | effect-witness | planned | 7 |
| VO-907c8a6c67d0814b7351 | T067 [US4] Generate a versioned topology ConfigMap from containerlab inspect output and | contract | positive | planned | 7 |
| VO-42967d2a92293a1070e2 | T068 [US4] Build orchestration and service-path panels for SDC | contract | positive | planned | 7 |
| VO-523320485966c04c00b2 | T069 [US4] Build pipeline dashboard panels for receiver/exporter health, queue fill, | contract | positive | planned | 7 |
| VO-141a39e14c417f18cd4f | T070 [US4] Add alerts for link/BGP loss, failed/degraded reconciliation, persistent | contract | positive | planned | 7 |
| VO-daca868a7905b267093e | T071 [US4] Test telemetry outage/recovery: reconciliation remains functional, status marks | contract | positive | planned | 7 |
| VO-1e433e498b366ee77474 | T072 Assert Prometheus is documented and tested as the metrics store; do not expose | contract | positive | planned | 7 |
| VO-cec08639c2a28e2e05c9 | T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM | contract | positive | planned | 8 |
| VO-f0b926b43d52fdce1de9 | T074 [P] Add dependency license, vulnerability, image provenance, and SBOM checks for the | contract | positive | planned | 8 |
| VO-39cc48bbf92ed9e68a5c | T074a Add a CI-enforced deny-list (case-insensitive, word boundaries) scanning the whole | contract | positive | planned | 8 |
| VO-07dc498663f1af559d83 | T075 [P] Complete operator/developer documentation, compatibility matrix, resource sizing, | contract | positive | planned | 8 |
| VO-bff2517d086e0ad761f6 | T076 Complete `scripts/provision.sh` as the primary non-interactive, idempotent ordered | contract | positive | planned | 8 |
| VO-859a163b82d1d7ad0d94 | T077 Complete `scripts/off.sh` for full and partial states with optional evidence capture, | contract | positive | planned | 8 |
| VO-c38bcf56cb0aceeb3106 | T078 Add Make wrappers for quickstart verification/test commands while keeping | contract | positive | planned | 8 |
| VO-cd69dbff14f28f2772d2 | T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, | contract | positive | planned | 8 |
| VO-c33f0d36340e60eafe06 | T079a Assert that the installed AINETOPS-owned CRD set contains exactly `SRv6Service.ainetops.io` | contract | positive | planned | 8 |
| VO-c6467c1aad43f1c7cb46 | T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an | contract | positive | planned | 8 |
| VO-1898512f96257c89d781 | T081 Author a runbook per alert defined in T070 (link/BGP loss, failed reconciliation, | contract | positive | planned | 9 |
| VO-fec401429e1e7b09148e | T082 [P] Define SLIs/SLOs for the lab control plane: reconcile success rate, time-to-Ready | contract | positive | planned | 9 |
| VO-743a4b294c887daea6db | T083 [P] Document and test the evidence export/restore procedure: capture SDC state, | contract | positive | planned | 9 |
| VO-f05d80e96bc91f2a31a5 | T084 Document and test the upgrade/rollback path for the pinned compatibility set: change | contract | positive | planned | 9 |
| VO-5119b18744895dd4760f | T085 Run a capacity and resource-exhaustion drill: measure actual host CPU/RAM/disk for | contract | positive | planned | 9 |
| VO-42bf9309bfb914b1d58c | T086 Run a failure game-day covering the Edge Cases in spec.md that automated tests do not | contract | positive | planned | 9 |
| VO-adf5cb98e52dce1eb95c | T087 [US3] Cold-start simulation: a fresh operator with no prior exposure provisions the | integration | effect-witness | planned | 9 |
| VO-f86e5714e01449949d51 | T088 [P] [US1] [US2] Day-2 workflow simulation: add a tenant service, modify an existing | contract | positive | planned | 9 |
| VO-de77f85feb448106218e | T089 [P] [US4] Operator-observability simulation: break one leaf-spine link and one | contract | positive | planned | 9 |
| VO-179b354284028a8dc6b8 | T090 [P] User-error simulation: apply malformed intent, an unsupported MPLS feature, wrong | contract | positive | planned | 9 |
| VO-d3836ab64c8ebe0d79eb | T091 Measure and record time-to-first-service and time-to-diagnosis from the simulations | contract | positive | planned | 9 |

## Phase gates

### Phase 1

- Gate ID: `GATE-phase-1`
- Required: yes
- Cumulative: no
- Obligations: `VO-ce3eeca45cee3d91adc3`, `VO-e944d3dcd900a11e2316`, `VO-c3ccb4b278c1b45cd324`, `VO-abf8ebaaa7255ba4ad27`, `VO-96ef82c55c68e552f180`, `VO-3feec31435627faace32`, `VO-8d0a38415c635e27b426`, `VO-4885269c94eff786a609`

### Phase 2

- Gate ID: `GATE-phase-2`
- Required: yes
- Cumulative: yes
- Obligations: `VO-ce3eeca45cee3d91adc3`, `VO-e944d3dcd900a11e2316`, `VO-c3ccb4b278c1b45cd324`, `VO-abf8ebaaa7255ba4ad27`, `VO-96ef82c55c68e552f180`, `VO-3feec31435627faace32`, `VO-8d0a38415c635e27b426`, `VO-4885269c94eff786a609`, `VO-c78953b4d417217fed57`, `VO-7da9012ea73d9d3536fa`, `VO-14f31bd9bedd3b3ea644`, `VO-0bcc810efc91a86a5bc6`, `VO-a7528052c383abd6cde2`, `VO-f4bb60a37a4e6baaefe5`, `VO-d785ed167f6cbab38578`, `VO-7fd7d1b1df3650feb53f`, `VO-639013e823d2ed354a41`

### Phase 3

- Gate ID: `GATE-phase-3`
- Required: yes
- Cumulative: yes
- Obligations: `VO-ce3eeca45cee3d91adc3`, `VO-e944d3dcd900a11e2316`, `VO-c3ccb4b278c1b45cd324`, `VO-abf8ebaaa7255ba4ad27`, `VO-96ef82c55c68e552f180`, `VO-3feec31435627faace32`, `VO-8d0a38415c635e27b426`, `VO-4885269c94eff786a609`, `VO-c78953b4d417217fed57`, `VO-7da9012ea73d9d3536fa`, `VO-14f31bd9bedd3b3ea644`, `VO-0bcc810efc91a86a5bc6`, `VO-a7528052c383abd6cde2`, `VO-f4bb60a37a4e6baaefe5`, `VO-d785ed167f6cbab38578`, `VO-7fd7d1b1df3650feb53f`, `VO-639013e823d2ed354a41`, `VO-9cb4228df5a48b280af5`, `VO-1bc8e079b300f3ec5137`, `VO-a0bda2a4c9cebe5d95d8`, `VO-4ac10627145b0a29fd29`, `VO-478311ea3158a0b5a823`, `VO-444acd0a2f7813635692`, `VO-3333241ad1182936b859`, `VO-bd3f1134f14130aceb96`

### Phase 4

- Gate ID: `GATE-phase-4`
- Required: yes
- Cumulative: yes
- Obligations: `VO-ce3eeca45cee3d91adc3`, `VO-e944d3dcd900a11e2316`, `VO-c3ccb4b278c1b45cd324`, `VO-abf8ebaaa7255ba4ad27`, `VO-96ef82c55c68e552f180`, `VO-3feec31435627faace32`, `VO-8d0a38415c635e27b426`, `VO-4885269c94eff786a609`, `VO-c78953b4d417217fed57`, `VO-7da9012ea73d9d3536fa`, `VO-14f31bd9bedd3b3ea644`, `VO-0bcc810efc91a86a5bc6`, `VO-a7528052c383abd6cde2`, `VO-f4bb60a37a4e6baaefe5`, `VO-d785ed167f6cbab38578`, `VO-7fd7d1b1df3650feb53f`, `VO-639013e823d2ed354a41`, `VO-9cb4228df5a48b280af5`, `VO-1bc8e079b300f3ec5137`, `VO-a0bda2a4c9cebe5d95d8`, `VO-4ac10627145b0a29fd29`, `VO-478311ea3158a0b5a823`, `VO-444acd0a2f7813635692`, `VO-3333241ad1182936b859`, `VO-bd3f1134f14130aceb96`, `VO-10f2a5aa71975c3cabf8`, `VO-7e4ee3276177948f78cc`, `VO-3e07612674de5f55b15e`, `VO-7ba202b6c49f1af461c6`, `VO-e067e5b1b7f1100f2215`, `VO-81cafc295ba509e54496`, `VO-5fd97f54267183f9af95`, `VO-8fe4127df0df70b7a2da`, `VO-b54d9d3f750b82a40209`, `VO-07f8b27c60dba9c452a3`, `VO-75e7fe520580a1631a50`, `VO-86a4a499ca09141db17a`, `VO-60ffdbcba9de3de06741`, `VO-fbfb46e286d5206e3cb1`, `VO-354b299fea44e3cf4b09`, `VO-7145be4f9c20f3ea9cb5`, `VO-1c9e4040526c3bf3973f`, `VO-9e7799dbe7c60b153a3c`, `VO-bfe6eb5c31630753e605`

### Phase 5

- Gate ID: `GATE-phase-5`
- Required: yes
- Cumulative: yes
- Obligations: `VO-ce3eeca45cee3d91adc3`, `VO-e944d3dcd900a11e2316`, `VO-c3ccb4b278c1b45cd324`, `VO-abf8ebaaa7255ba4ad27`, `VO-96ef82c55c68e552f180`, `VO-3feec31435627faace32`, `VO-8d0a38415c635e27b426`, `VO-4885269c94eff786a609`, `VO-c78953b4d417217fed57`, `VO-7da9012ea73d9d3536fa`, `VO-14f31bd9bedd3b3ea644`, `VO-0bcc810efc91a86a5bc6`, `VO-a7528052c383abd6cde2`, `VO-f4bb60a37a4e6baaefe5`, `VO-d785ed167f6cbab38578`, `VO-7fd7d1b1df3650feb53f`, `VO-639013e823d2ed354a41`, `VO-9cb4228df5a48b280af5`, `VO-1bc8e079b300f3ec5137`, `VO-a0bda2a4c9cebe5d95d8`, `VO-4ac10627145b0a29fd29`, `VO-478311ea3158a0b5a823`, `VO-444acd0a2f7813635692`, `VO-3333241ad1182936b859`, `VO-bd3f1134f14130aceb96`, `VO-10f2a5aa71975c3cabf8`, `VO-7e4ee3276177948f78cc`, `VO-3e07612674de5f55b15e`, `VO-7ba202b6c49f1af461c6`, `VO-e067e5b1b7f1100f2215`, `VO-81cafc295ba509e54496`, `VO-5fd97f54267183f9af95`, `VO-8fe4127df0df70b7a2da`, `VO-b54d9d3f750b82a40209`, `VO-07f8b27c60dba9c452a3`, `VO-75e7fe520580a1631a50`, `VO-86a4a499ca09141db17a`, `VO-60ffdbcba9de3de06741`, `VO-fbfb46e286d5206e3cb1`, `VO-354b299fea44e3cf4b09`, `VO-7145be4f9c20f3ea9cb5`, `VO-1c9e4040526c3bf3973f`, `VO-9e7799dbe7c60b153a3c`, `VO-bfe6eb5c31630753e605`, `VO-f4406e3b365b81b0356c`, `VO-a1a34cfefd73bd2714bc`, `VO-6af57051fa79a545caea`, `VO-e9e2b214c5b8b533b867`, `VO-2a596388791ba51056f0`, `VO-36cc3e7485520b2d17ff`, `VO-2a21fb268248d2cf735b`, `VO-8f111b83f1f0b3ea564b`, `VO-d300c6db6ce06dfd276a`, `VO-24f6b0303f5fe8d755f1`, `VO-817efa5a288ee6449f98`, `VO-7fec1413d8abcfcf6487`, `VO-6e31c53f7ce1891d7fe7`, `VO-1dbb24e8c9b928f5f3ae`

### Phase 6

- Gate ID: `GATE-phase-6`
- Required: yes
- Cumulative: yes
- Obligations: `VO-ce3eeca45cee3d91adc3`, `VO-e944d3dcd900a11e2316`, `VO-c3ccb4b278c1b45cd324`, `VO-abf8ebaaa7255ba4ad27`, `VO-96ef82c55c68e552f180`, `VO-3feec31435627faace32`, `VO-8d0a38415c635e27b426`, `VO-4885269c94eff786a609`, `VO-c78953b4d417217fed57`, `VO-7da9012ea73d9d3536fa`, `VO-14f31bd9bedd3b3ea644`, `VO-0bcc810efc91a86a5bc6`, `VO-a7528052c383abd6cde2`, `VO-f4bb60a37a4e6baaefe5`, `VO-d785ed167f6cbab38578`, `VO-7fd7d1b1df3650feb53f`, `VO-639013e823d2ed354a41`, `VO-9cb4228df5a48b280af5`, `VO-1bc8e079b300f3ec5137`, `VO-a0bda2a4c9cebe5d95d8`, `VO-4ac10627145b0a29fd29`, `VO-478311ea3158a0b5a823`, `VO-444acd0a2f7813635692`, `VO-3333241ad1182936b859`, `VO-bd3f1134f14130aceb96`, `VO-10f2a5aa71975c3cabf8`, `VO-7e4ee3276177948f78cc`, `VO-3e07612674de5f55b15e`, `VO-7ba202b6c49f1af461c6`, `VO-e067e5b1b7f1100f2215`, `VO-81cafc295ba509e54496`, `VO-5fd97f54267183f9af95`, `VO-8fe4127df0df70b7a2da`, `VO-b54d9d3f750b82a40209`, `VO-07f8b27c60dba9c452a3`, `VO-75e7fe520580a1631a50`, `VO-86a4a499ca09141db17a`, `VO-60ffdbcba9de3de06741`, `VO-fbfb46e286d5206e3cb1`, `VO-354b299fea44e3cf4b09`, `VO-7145be4f9c20f3ea9cb5`, `VO-1c9e4040526c3bf3973f`, `VO-9e7799dbe7c60b153a3c`, `VO-bfe6eb5c31630753e605`, `VO-f4406e3b365b81b0356c`, `VO-a1a34cfefd73bd2714bc`, `VO-6af57051fa79a545caea`, `VO-e9e2b214c5b8b533b867`, `VO-2a596388791ba51056f0`, `VO-36cc3e7485520b2d17ff`, `VO-2a21fb268248d2cf735b`, `VO-8f111b83f1f0b3ea564b`, `VO-d300c6db6ce06dfd276a`, `VO-24f6b0303f5fe8d755f1`, `VO-817efa5a288ee6449f98`, `VO-7fec1413d8abcfcf6487`, `VO-6e31c53f7ce1891d7fe7`, `VO-1dbb24e8c9b928f5f3ae`, `VO-402dd008e37d1e159e78`, `VO-bb9db15d763b6b8adc66`, `VO-5c49289faeea3172565e`, `VO-6f7a083706d4fa31e390`, `VO-e655a78b0123af5832f8`, `VO-688be61eb6478483cb2d`, `VO-c8a6c5410985a7c8fba9`, `VO-fe56d3af6e7b8b9a8b6a`, `VO-87da5ecb90151b7789a4`, `VO-df1c6a2302947c1b7b7d`, `VO-b351881d6e891c68fdcb`

### Phase 7

- Gate ID: `GATE-phase-7`
- Required: yes
- Cumulative: yes
- Obligations: `VO-ce3eeca45cee3d91adc3`, `VO-e944d3dcd900a11e2316`, `VO-c3ccb4b278c1b45cd324`, `VO-abf8ebaaa7255ba4ad27`, `VO-96ef82c55c68e552f180`, `VO-3feec31435627faace32`, `VO-8d0a38415c635e27b426`, `VO-4885269c94eff786a609`, `VO-c78953b4d417217fed57`, `VO-7da9012ea73d9d3536fa`, `VO-14f31bd9bedd3b3ea644`, `VO-0bcc810efc91a86a5bc6`, `VO-a7528052c383abd6cde2`, `VO-f4bb60a37a4e6baaefe5`, `VO-d785ed167f6cbab38578`, `VO-7fd7d1b1df3650feb53f`, `VO-639013e823d2ed354a41`, `VO-9cb4228df5a48b280af5`, `VO-1bc8e079b300f3ec5137`, `VO-a0bda2a4c9cebe5d95d8`, `VO-4ac10627145b0a29fd29`, `VO-478311ea3158a0b5a823`, `VO-444acd0a2f7813635692`, `VO-3333241ad1182936b859`, `VO-bd3f1134f14130aceb96`, `VO-10f2a5aa71975c3cabf8`, `VO-7e4ee3276177948f78cc`, `VO-3e07612674de5f55b15e`, `VO-7ba202b6c49f1af461c6`, `VO-e067e5b1b7f1100f2215`, `VO-81cafc295ba509e54496`, `VO-5fd97f54267183f9af95`, `VO-8fe4127df0df70b7a2da`, `VO-b54d9d3f750b82a40209`, `VO-07f8b27c60dba9c452a3`, `VO-75e7fe520580a1631a50`, `VO-86a4a499ca09141db17a`, `VO-60ffdbcba9de3de06741`, `VO-fbfb46e286d5206e3cb1`, `VO-354b299fea44e3cf4b09`, `VO-7145be4f9c20f3ea9cb5`, `VO-1c9e4040526c3bf3973f`, `VO-9e7799dbe7c60b153a3c`, `VO-bfe6eb5c31630753e605`, `VO-f4406e3b365b81b0356c`, `VO-a1a34cfefd73bd2714bc`, `VO-6af57051fa79a545caea`, `VO-e9e2b214c5b8b533b867`, `VO-2a596388791ba51056f0`, `VO-36cc3e7485520b2d17ff`, `VO-2a21fb268248d2cf735b`, `VO-8f111b83f1f0b3ea564b`, `VO-d300c6db6ce06dfd276a`, `VO-24f6b0303f5fe8d755f1`, `VO-817efa5a288ee6449f98`, `VO-7fec1413d8abcfcf6487`, `VO-6e31c53f7ce1891d7fe7`, `VO-1dbb24e8c9b928f5f3ae`, `VO-402dd008e37d1e159e78`, `VO-bb9db15d763b6b8adc66`, `VO-5c49289faeea3172565e`, `VO-6f7a083706d4fa31e390`, `VO-e655a78b0123af5832f8`, `VO-688be61eb6478483cb2d`, `VO-c8a6c5410985a7c8fba9`, `VO-fe56d3af6e7b8b9a8b6a`, `VO-87da5ecb90151b7789a4`, `VO-df1c6a2302947c1b7b7d`, `VO-b351881d6e891c68fdcb`, `VO-998fdb1264aab3501a2e`, `VO-44680e3e69a337508ca2`, `VO-3a08068ff740db6052ca`, `VO-4960973806850b426b40`, `VO-5f1a6a50e73d4bfa93a7`, `VO-907c8a6c67d0814b7351`, `VO-42967d2a92293a1070e2`, `VO-523320485966c04c00b2`, `VO-141a39e14c417f18cd4f`, `VO-daca868a7905b267093e`, `VO-1e433e498b366ee77474`

### Phase 8

- Gate ID: `GATE-phase-8`
- Required: yes
- Cumulative: yes
- Obligations: `VO-ce3eeca45cee3d91adc3`, `VO-e944d3dcd900a11e2316`, `VO-c3ccb4b278c1b45cd324`, `VO-abf8ebaaa7255ba4ad27`, `VO-96ef82c55c68e552f180`, `VO-3feec31435627faace32`, `VO-8d0a38415c635e27b426`, `VO-4885269c94eff786a609`, `VO-c78953b4d417217fed57`, `VO-7da9012ea73d9d3536fa`, `VO-14f31bd9bedd3b3ea644`, `VO-0bcc810efc91a86a5bc6`, `VO-a7528052c383abd6cde2`, `VO-f4bb60a37a4e6baaefe5`, `VO-d785ed167f6cbab38578`, `VO-7fd7d1b1df3650feb53f`, `VO-639013e823d2ed354a41`, `VO-9cb4228df5a48b280af5`, `VO-1bc8e079b300f3ec5137`, `VO-a0bda2a4c9cebe5d95d8`, `VO-4ac10627145b0a29fd29`, `VO-478311ea3158a0b5a823`, `VO-444acd0a2f7813635692`, `VO-3333241ad1182936b859`, `VO-bd3f1134f14130aceb96`, `VO-10f2a5aa71975c3cabf8`, `VO-7e4ee3276177948f78cc`, `VO-3e07612674de5f55b15e`, `VO-7ba202b6c49f1af461c6`, `VO-e067e5b1b7f1100f2215`, `VO-81cafc295ba509e54496`, `VO-5fd97f54267183f9af95`, `VO-8fe4127df0df70b7a2da`, `VO-b54d9d3f750b82a40209`, `VO-07f8b27c60dba9c452a3`, `VO-75e7fe520580a1631a50`, `VO-86a4a499ca09141db17a`, `VO-60ffdbcba9de3de06741`, `VO-fbfb46e286d5206e3cb1`, `VO-354b299fea44e3cf4b09`, `VO-7145be4f9c20f3ea9cb5`, `VO-1c9e4040526c3bf3973f`, `VO-9e7799dbe7c60b153a3c`, `VO-bfe6eb5c31630753e605`, `VO-f4406e3b365b81b0356c`, `VO-a1a34cfefd73bd2714bc`, `VO-6af57051fa79a545caea`, `VO-e9e2b214c5b8b533b867`, `VO-2a596388791ba51056f0`, `VO-36cc3e7485520b2d17ff`, `VO-2a21fb268248d2cf735b`, `VO-8f111b83f1f0b3ea564b`, `VO-d300c6db6ce06dfd276a`, `VO-24f6b0303f5fe8d755f1`, `VO-817efa5a288ee6449f98`, `VO-7fec1413d8abcfcf6487`, `VO-6e31c53f7ce1891d7fe7`, `VO-1dbb24e8c9b928f5f3ae`, `VO-402dd008e37d1e159e78`, `VO-bb9db15d763b6b8adc66`, `VO-5c49289faeea3172565e`, `VO-6f7a083706d4fa31e390`, `VO-e655a78b0123af5832f8`, `VO-688be61eb6478483cb2d`, `VO-c8a6c5410985a7c8fba9`, `VO-fe56d3af6e7b8b9a8b6a`, `VO-87da5ecb90151b7789a4`, `VO-df1c6a2302947c1b7b7d`, `VO-b351881d6e891c68fdcb`, `VO-998fdb1264aab3501a2e`, `VO-44680e3e69a337508ca2`, `VO-3a08068ff740db6052ca`, `VO-4960973806850b426b40`, `VO-5f1a6a50e73d4bfa93a7`, `VO-907c8a6c67d0814b7351`, `VO-42967d2a92293a1070e2`, `VO-523320485966c04c00b2`, `VO-141a39e14c417f18cd4f`, `VO-daca868a7905b267093e`, `VO-1e433e498b366ee77474`, `VO-cec08639c2a28e2e05c9`, `VO-f0b926b43d52fdce1de9`, `VO-39cc48bbf92ed9e68a5c`, `VO-07dc498663f1af559d83`, `VO-bff2517d086e0ad761f6`, `VO-859a163b82d1d7ad0d94`, `VO-c38bcf56cb0aceeb3106`, `VO-cd69dbff14f28f2772d2`, `VO-c33f0d36340e60eafe06`, `VO-c6467c1aad43f1c7cb46`

### Phase 9

- Gate ID: `GATE-phase-9`
- Required: yes
- Cumulative: yes
- Obligations: `VO-ce3eeca45cee3d91adc3`, `VO-e944d3dcd900a11e2316`, `VO-c3ccb4b278c1b45cd324`, `VO-abf8ebaaa7255ba4ad27`, `VO-96ef82c55c68e552f180`, `VO-3feec31435627faace32`, `VO-8d0a38415c635e27b426`, `VO-4885269c94eff786a609`, `VO-c78953b4d417217fed57`, `VO-7da9012ea73d9d3536fa`, `VO-14f31bd9bedd3b3ea644`, `VO-0bcc810efc91a86a5bc6`, `VO-a7528052c383abd6cde2`, `VO-f4bb60a37a4e6baaefe5`, `VO-d785ed167f6cbab38578`, `VO-7fd7d1b1df3650feb53f`, `VO-639013e823d2ed354a41`, `VO-9cb4228df5a48b280af5`, `VO-1bc8e079b300f3ec5137`, `VO-a0bda2a4c9cebe5d95d8`, `VO-4ac10627145b0a29fd29`, `VO-478311ea3158a0b5a823`, `VO-444acd0a2f7813635692`, `VO-3333241ad1182936b859`, `VO-bd3f1134f14130aceb96`, `VO-10f2a5aa71975c3cabf8`, `VO-7e4ee3276177948f78cc`, `VO-3e07612674de5f55b15e`, `VO-7ba202b6c49f1af461c6`, `VO-e067e5b1b7f1100f2215`, `VO-81cafc295ba509e54496`, `VO-5fd97f54267183f9af95`, `VO-8fe4127df0df70b7a2da`, `VO-b54d9d3f750b82a40209`, `VO-07f8b27c60dba9c452a3`, `VO-75e7fe520580a1631a50`, `VO-86a4a499ca09141db17a`, `VO-60ffdbcba9de3de06741`, `VO-fbfb46e286d5206e3cb1`, `VO-354b299fea44e3cf4b09`, `VO-7145be4f9c20f3ea9cb5`, `VO-1c9e4040526c3bf3973f`, `VO-9e7799dbe7c60b153a3c`, `VO-bfe6eb5c31630753e605`, `VO-f4406e3b365b81b0356c`, `VO-a1a34cfefd73bd2714bc`, `VO-6af57051fa79a545caea`, `VO-e9e2b214c5b8b533b867`, `VO-2a596388791ba51056f0`, `VO-36cc3e7485520b2d17ff`, `VO-2a21fb268248d2cf735b`, `VO-8f111b83f1f0b3ea564b`, `VO-d300c6db6ce06dfd276a`, `VO-24f6b0303f5fe8d755f1`, `VO-817efa5a288ee6449f98`, `VO-7fec1413d8abcfcf6487`, `VO-6e31c53f7ce1891d7fe7`, `VO-1dbb24e8c9b928f5f3ae`, `VO-402dd008e37d1e159e78`, `VO-bb9db15d763b6b8adc66`, `VO-5c49289faeea3172565e`, `VO-6f7a083706d4fa31e390`, `VO-e655a78b0123af5832f8`, `VO-688be61eb6478483cb2d`, `VO-c8a6c5410985a7c8fba9`, `VO-fe56d3af6e7b8b9a8b6a`, `VO-87da5ecb90151b7789a4`, `VO-df1c6a2302947c1b7b7d`, `VO-b351881d6e891c68fdcb`, `VO-998fdb1264aab3501a2e`, `VO-44680e3e69a337508ca2`, `VO-3a08068ff740db6052ca`, `VO-4960973806850b426b40`, `VO-5f1a6a50e73d4bfa93a7`, `VO-907c8a6c67d0814b7351`, `VO-42967d2a92293a1070e2`, `VO-523320485966c04c00b2`, `VO-141a39e14c417f18cd4f`, `VO-daca868a7905b267093e`, `VO-1e433e498b366ee77474`, `VO-cec08639c2a28e2e05c9`, `VO-f0b926b43d52fdce1de9`, `VO-39cc48bbf92ed9e68a5c`, `VO-07dc498663f1af559d83`, `VO-bff2517d086e0ad761f6`, `VO-859a163b82d1d7ad0d94`, `VO-c38bcf56cb0aceeb3106`, `VO-cd69dbff14f28f2772d2`, `VO-c33f0d36340e60eafe06`, `VO-c6467c1aad43f1c7cb46`, `VO-1898512f96257c89d781`, `VO-fec401429e1e7b09148e`, `VO-743a4b294c887daea6db`, `VO-f05d80e96bc91f2a31a5`, `VO-5119b18744895dd4760f`, `VO-42bf9309bfb914b1d58c`, `VO-adf5cb98e52dce1eb95c`, `VO-f86e5714e01449949d51`, `VO-de77f85feb448106218e`, `VO-179b354284028a8dc6b8`, `VO-d3836ab64c8ebe0d79eb`

## Effect-witness policy

A mutation response is never sufficient evidence. Observe resulting state through an independent read path.

## Automated commands

### Run Go tests

- Command ID: `CMD-7b0518e1174ca872060e`
- Absolute working directory: `/root/ainetops-demo`

```bash
/usr/lib/go-1.24/bin/go test ./...
```

## Ambiguities and blockers

- None.
