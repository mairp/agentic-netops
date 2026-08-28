<!-- wiggum-verification-plan content-hash: f56470327f776adaedafe077f64fcb522f8f3ab60d728791d0afaaaec1c934a7 -->
# Verification and Test Automation Plan

## Provenance

- Plan ID: `verification-ef0ad7e7eb82ac2dcf7b`
- Plan content hash: `f56470327f776adaedafe077f64fcb522f8f3ab60d728791d0afaaaec1c934a7`
- Source bundle ID: `0X8147VC0P13DYR9CW6SHKD8WF`
- Source semantic hash: `751c4dfbc4879208295699a48dedcf90cb17c1fe9a61d87dfefb6080bfbedf19`
- Source specification: `/root/ainetops-demo/specs/001-ainetops-sonic-evpn-fabric/tasks.md`
- Absolute workdir: `/root/ainetops-demo`
- Project fingerprint: `7fc3fbb463094f51816710092c33842b41fb6153299604f301fcc56071b250cf`

## Coverage obligations

| ID | Outcome | Level | Kind | Automation | Phase |
| --- | --- | --- | --- | --- | --- |
| VO-9f46c3eb28e58bd1fad2 | T001 Create the implementation directory structure from [plan.md](./plan.md), including | integration | effect-witness | planned | 1 |
| VO-ccceee4bd62e391114c5 | T002 Research and select one mutually compatible Kind binary/node image, Kubernetes, | contract | positive | planned | 1 |
| VO-a2c92a2c201f9997df98 | T003 Select and record a pinned containerlab version and both SONiC profile image | contract | positive | planned | 1 |
| VO-85703cd3e2372ffb6509 | T004 Select the SONiC/OpenConfig YANG schema commit and record its compatibility with | integration | effect-witness | planned | 1 |
| VO-be7ee8383e989b214a82 | T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, the Grafana Flow plugin, and | contract | positive | planned | 1 |
| VO-30a4c44a421cc90e23a2 | T006 Implement `make verify-pins` to reject `latest`, floating refs, missing digests, and | contract | positive | planned | 1 |
| VO-6bd91de95f0bb8ab4ce8 | T007 Implement reusable strict-shell preflight for host resources, Kind/runtime | contract | positive | planned | 1 |
| VO-82f809605d10cef51716 | T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side | contract | positive | planned | 1 |
| VO-afa8425c0ecdb9e9d3d8 | T009 [US3] Author `lab/topology.clab.yml` with `spine01`, `spine02`, `leaf01`, `leaf02`, | contract | positive | planned | 2 |
| VO-fd0f1c4858c4961584e0 | T010 [P] [US3] Create the `sonic-vs` profile with bootstrap limited to management, TLS, | integration | effect-witness | planned | 2 |
| VO-195afae65c44aa3dcf34 | T011 [P] [US3] Create the `sonic-vm` conformance overlay and document KVM/nested | integration | effect-witness | planned | 2 |
| VO-5bb9225b782568f81af2 | T012 [P] [US3] Create Linux endpoint images/configuration and deterministic dual-stack | integration | effect-witness | planned | 2 |
| VO-672489b9771d8547e192 | T013 [US3] Implement SONiC gNMI Capabilities/Get/Set/Subscribe qualification tests | contract | positive | planned | 2 |
| VO-f725b5aa29dfa9608556 | T014 [P] [US3] Implement persistent configuration and required OpenConfig/SONiC YANG path | contract | positive | planned | 2 |
| VO-04c9121f3b5051968ee3 | T015 [P] [US3] Implement BGP EVPN/VXLAN Type 2/3/5 and SRv6 IPv6-underlay, | contract | positive | planned | 2 |
| VO-3e6c7321565e6a6b5473 | T016 [US3] Implement `make lab-qualify` so any failed capability blocks downstream tests | contract | positive | planned | 2 |
| VO-ac289c2bf8b36b353ebb | T017 [US3] Implement idempotent containerlab deploy/inspect/destroy script phases callable | integration | effect-witness | planned | 2 |
| VO-c292a5c1db1b91cd8050 | T018 Author `config/kind/cluster.yaml` and idempotent Kind create/delete phases with a | integration | effect-witness | planned | 3 |
| VO-0f4e897f6670173b34e4 | T019 Implement creation/ownership labeling of the dedicated Docker management network, | contract | positive | planned | 3 |
| VO-a8a3a9c61b1e7e884295 | T020 Install pinned Kubenet/KUID CRDs/controllers inside Kind and wait for current- | integration | effect-witness | planned | 3 |
| VO-779292f79fa9f59439bf | T021 Install pinned SDC CRDs and schema/config/data/cache components inside Kind with | integration | effect-witness | planned | 3 |
| VO-89556224f3b7bbdb017c | T022 [P] Create least-privilege namespaces, service accounts, RBAC, network policies, and | integration | effect-witness | planned | 3 |
| VO-f5434170bc0fc81c39e5 | T023 Author the Kind deployment manifests/Helm values for the later AINETOPS provider and | contract | positive | planned | 3 |
| VO-58d01e895466b225a4d1 | T024 Create the exact pinned SONiC `Schema`, connection profile, sync profile, and | integration | effect-witness | planned | 3 |
| VO-25f9fdd579584d745685 | T025 Create topology, IP/ASN/ID indices, claims/pools, and fabric design manifests using | integration | effect-witness | planned | 3 |
| VO-6ae9fe4bdc7236be4ddd | T026 Scaffold the Go provider manager (`cmd/sonic-provider/`, `controllers/sonicprovider/`) | contract | positive | planned | 4 |
| VO-d1482f465caa53b6427d | T026a Scaffold the SRv6 service controller binary and reconciler | contract | positive | planned | 4 |
| VO-2702a9dae6b3e7c4de5d | T027 Define canonical internal structs for interfaces, loopbacks, BGP, network instances, | contract | positive | planned | 4 |
| VO-d7dfdf45b4cbe519dd0a | T027a Author the required `SRv6Service.ainetops.io/v1alpha1` CRD and scaffolding: | contract | positive | planned | 4 |
| VO-0f77de4d45b78effc56c | T028 [P] Implement `NetworkDevice` selection, dependency watches/indexes, current- | contract | positive | planned | 4 |
| VO-44ab20617424b3d9b9d6 | T029 [P] Implement compatibility-set validation for image, schema, mapping, and upstream | contract | positive | planned | 4 |
| VO-1cb757c3e563d18c6a77 | T029a Produce a per-path OpenConfig-vs-SONiC-native register for all rendered YANG paths; | contract | positive | planned | 4 |
| VO-1fd8ff0891858451b68c | T030 Implement abstract-model normalization and reject incomplete, unknown, or conflicting | contract | positive | planned | 4 |
| VO-1ef6e0d0424a70793461 | T031 [P] Implement qualified interface/loopback/MTU and dual-stack IPv4 `/31` plus IPv6 | contract | positive | planned | 4 |
| VO-41f0800bb583fb67a11a | T032 [P] Implement qualified BGP global/neighbor and EVPN address-family renderers | contract | positive | planned | 4 |
| VO-de6cfc1d65b0f4ba0c67 | T033 [P] Implement VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers | contract | positive | planned | 4 |
| VO-15f4c9a51436a87e9c45 | T034 [P] Implement VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, | contract | positive | planned | 4 |
| VO-43501490db482f1a1c59 | T035 Compose deterministic ordered output, stable generated names, canonical hashes, | contract | positive | planned | 4 |
| VO-bdec9b841a44e6987924 | T036 Integrate offline SDC/schema validation; emit no changed Config when validation fails | contract | positive | planned | 4 |
| VO-a499fa0552380fa18d51 | T037 Implement server-side apply with a dedicated field manager, explicit priority, | contract | positive | planned | 4 |
| VO-31bcca4c629d4495751e | T038 Observe SDC Config/Target/Deviation status and propagate standard per-device and | contract | positive | planned | 4 |
| VO-79d0bb68c7d504eb2755 | T039 Implement bounded backoff/jitter and terminal-vs-transient error classification | contract | positive | planned | 4 |
| VO-b4b933d8d0730c0c9944 | T040 Implement ordered finalization: delete owned SDC intent, confirm/timeout, release | integration | effect-witness | planned | 4 |
| VO-5139c3ce469e55e0ebc0 | T041 Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, | contract | positive | planned | 4 |
| VO-fb27730c3b87691e83ad | T041a Build the T026a SRv6 service controller binary, load it, and deploy it inside Kind | integration | effect-witness | planned | 5 |
| VO-a9f22ad37d345e006bfe | T042 [US3] Apply the default Kubenet Network and reconcile dual-stack routed leaf-spine | contract | positive | planned | 5 |
| VO-4c82072e941b140614f9 | T043 [US3] Add verification for all expected underlay/EVPN sessions, loopback reachability, | contract | positive | planned | 5 |
| VO-7dddbf2c4016af0acd16 | T044 [P] [US1] Add a bridged L2 tenant example with two cross-leaf attachments, VLAN, | contract | positive | planned | 5 |
| VO-1f8d441748c7bd01b0f8 | T045 [P] [US1] Add a routed L3 tenant example with VRF, L3VNI, RD/RT, prefixes, and Type-5 | contract | positive | planned | 5 |
| VO-9e6be54b63f5644848fa | T046 [P] [US1] Add a symmetric-IRB example with L2/L3 VNIs, gateway addresses, and two | contract | positive | planned | 5 |
| VO-b34481fc05c58ac0e4e3 | T047 [US3] Implement EVPN client traffic tests: cross-leaf L2 reachability, intra-VRF L3/IRB, | contract | positive | planned | 5 |
| VO-4554e0ee27ef3a00d04d | T047a [US3] Implement MTU and ECMP tests: verify maximum effective MTU accommodates VXLAN overhead | contract | positive | planned | 5 |
| VO-c22c364bc3888e3aa8d3 | T047b [US5] Implement SRv6 capture and counter tests between dedicated clients: capture | contract | positive | planned | 5 |
| VO-50090ba3f6512d5f8eff | T047c [US5] Implement failover and operator-directed path-change tests: force primary failure, | contract | positive | planned | 5 |
| VO-47eef71e39da0bedf9a5 | T048 [US2] Add repeat-apply proof: unchanged intent produces zero SDC spec writes and zero | contract | positive | planned | 5 |
| VO-13ef51ff54617a759318 | T049 [US2] Add partial target failure/recovery, provider restart mid-transaction, and | contract | positive | planned | 5 |
| VO-c5bbeee56b0797caa9e8 | T050 [US2] Add managed-path drift restoration and unmanaged-path preservation tests | contract | positive | planned | 5 |
| VO-34344e579358253fdb30 | T051 [US2] Add update and delete tests proving shared fabric state and unrelated claims | integration | effect-witness | planned | 5 |
| VO-b5245cfe8692376af119 | T052 Define a strict normalized input schema for service ID, type, tenant, endpoints, | contract | positive | planned | 6 |
| VO-db2598e32f6f21e1d55d | T053 [P] [US1] Implement VPLS/multipoint-L2VPN to bridge/L2VNI translation | contract | positive | planned | 6 |
| VO-8830b3bcffcedacf6d51 | T054 [P] [US1] Implement L3VPN to VRF/L3VNI/RD/RT/Type-5 translation | contract | positive | planned | 6 |
| VO-e03b5ef3e6babf111591 | T055 [P] [US1] Implement VPWS/E-Line to two-attachment L2VNI with explicit limited- | contract | positive | planned | 6 |
| VO-e8d65a5d364eebb383b4 | T056 [P] [US1] Implement integrated L2/L3 to symmetric-IRB translation | contract | positive | planned | 6 |
| VO-6bd4e120341dde856299 | T057 [US1] Implement all-or-nothing validation and structured unsupported-feature results | contract | positive | planned | 6 |
| VO-00e3c9a00dcc564ab44f | T058 Add deterministic CLI/library output with stable provenance annotations on generated | contract | positive | planned | 6 |
| VO-8fd525d0c496af1fa4b5 | T058a Package the migration translator as a deterministic library plus CLI binary | contract | positive | planned | 6 |
| VO-ecff1cc23cd30ed63dd2 | T059 Add table/golden tests for every supported, limited, unsupported, collision, and | contract | positive | planned | 6 |
| VO-7f9e51b7961d6fe60567 | T060 Decide from workflow evidence whether annotations/Git review meet audit needs; only | contract | positive | planned | 6 |
| VO-056bd8761b973f3ad8bc | T061 If T060 enables the CRD, add structural/CEL validation, status subresource, RBAC, | contract | positive | planned | 6 |
| VO-4cbb3fd9287b43a8c568 | T062 Inventory metrics available from the pinned SONiC schema, SDC, provider, Kubernetes, | contract | positive | planned | 7 |
| VO-7772a592df54868fd695 | T063 Deploy gNMIc inside Kind as the sole SONiC device-metric collector, export OTLP to | integration | effect-witness | planned | 7 |
| VO-acde1320264805533177 | T064 [P] Deploy OTel Collector inside Kind with receivers, Kubernetes enrichment, | integration | effect-witness | planned | 7 |
| VO-40f5129c9a6eb2dba795 | T065 [P] Deploy Prometheus and required operator resources inside Kind with a PVC, pinned | integration | effect-witness | planned | 7 |
| VO-702987d2b40f218ffef9 | T066 [P] Deploy Grafana inside Kind with a PVC where required, Secret-based credentials, | integration | effect-witness | planned | 7 |
| VO-8e57358ced826d89be85 | T067 [US4] Generate a versioned topology ConfigMap from containerlab inspect output and | contract | positive | planned | 7 |
| VO-2a103a2314a25cb8a5d3 | T068 [US4] Build orchestration and service-path panels for SDC | contract | positive | planned | 7 |
| VO-1010f91be22c528c4aa2 | T069 [US4] Build pipeline dashboard panels for receiver/exporter health, queue fill, | contract | positive | planned | 7 |
| VO-c69fb81dc51f49ba14c5 | T070 [US4] Add alerts for link/BGP loss, failed/degraded reconciliation, persistent | contract | positive | planned | 7 |
| VO-ee9cae08517d5346a12e | T071 [US4] Test telemetry outage/recovery: reconciliation remains functional, status marks | contract | positive | planned | 7 |
| VO-5c3e24deb467a61f7375 | T072 Assert Prometheus is documented and tested as the metrics store; do not expose | contract | positive | planned | 7 |
| VO-2ac8f48fdffd009e097d | T073 Audit RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM | contract | positive | planned | 8 |
| VO-ae7e6709fee471285ba5 | T074 [P] Add dependency license, vulnerability, image provenance, and SBOM checks for the | contract | positive | planned | 8 |
| VO-96f56366d7bd57aa6e89 | T074a Add a CI-enforced deny-list (case-insensitive, word boundaries) scanning the whole | contract | positive | planned | 8 |
| VO-e65eb8b20d3123faf0f1 | T075 [P] Complete operator/developer documentation, compatibility matrix, resource sizing, | contract | positive | planned | 8 |
| VO-b84282c3534000a4f8ed | T076 Complete `scripts/provision.sh` as the primary non-interactive, idempotent ordered | contract | positive | planned | 8 |
| VO-f14678dc981207cf35e9 | T077 Complete `scripts/off.sh` for full and partial states with optional evidence capture, | contract | positive | planned | 8 |
| VO-28f8a9a2cafc76e72ca7 | T078 Add Make wrappers for quickstart verification/test commands while keeping | contract | positive | planned | 8 |
| VO-d8434673434071887d85 | T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, | contract | positive | planned | 8 |
| VO-3a22a7a89d8faf5a6abd | T079a Assert that the installed AINETOPS-owned CRD set contains exactly `SRv6Service.ainetops.io` | contract | positive | planned | 8 |
| VO-83dcb5e1f8f2e7bb8c36 | T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an | contract | positive | planned | 8 |
| VO-12800b0da6e5f79c8841 | T081 Author a runbook per alert defined in T070 (link/BGP loss, failed reconciliation, | contract | positive | planned | 9 |
| VO-49a37696182d233fcca0 | T082 [P] Define SLIs/SLOs for the lab control plane: reconcile success rate, time-to-Ready | contract | positive | planned | 9 |
| VO-6c7a5cc860e03427822c | T083 [P] Document and test the evidence export/restore procedure: capture SDC state, | contract | positive | planned | 9 |
| VO-7b4ccf19a4c734d7e2a6 | T084 Document and test the upgrade/rollback path for the pinned compatibility set: change | contract | positive | planned | 9 |
| VO-67a800f5260a7bc02738 | T085 Run a capacity and resource-exhaustion drill: measure actual host CPU/RAM/disk for | contract | positive | planned | 9 |
| VO-901da35e345226f6cc19 | T086 Run a failure game-day covering the Edge Cases in spec.md that automated tests do not | contract | positive | planned | 9 |
| VO-cc4f6342659867995225 | T087 [US3] Cold-start simulation: a fresh operator with no prior exposure provisions the | integration | effect-witness | planned | 9 |
| VO-190af6c74d36bf615f38 | T088 [P] [US1] [US2] Day-2 workflow simulation: add a tenant service, modify an existing | contract | positive | planned | 9 |
| VO-8b87ffb02209868f327f | T089 [P] [US4] Operator-observability simulation: break one leaf-spine link and one | contract | positive | planned | 9 |
| VO-1d7c0b1827ecd6108f49 | T090 [P] User-error simulation: apply malformed intent, an unsupported MPLS feature, wrong | contract | positive | planned | 9 |
| VO-5f862404d000455fa6e8 | T091 Measure and record time-to-first-service and time-to-diagnosis from the simulations | contract | positive | planned | 9 |

## Phase gates

### Phase 1

- Gate ID: `GATE-phase-1`
- Required: yes
- Cumulative: no
- Obligations: `VO-9f46c3eb28e58bd1fad2`, `VO-ccceee4bd62e391114c5`, `VO-a2c92a2c201f9997df98`, `VO-85703cd3e2372ffb6509`, `VO-be7ee8383e989b214a82`, `VO-30a4c44a421cc90e23a2`, `VO-6bd91de95f0bb8ab4ce8`, `VO-82f809605d10cef51716`

### Phase 2

- Gate ID: `GATE-phase-2`
- Required: yes
- Cumulative: yes
- Obligations: `VO-9f46c3eb28e58bd1fad2`, `VO-ccceee4bd62e391114c5`, `VO-a2c92a2c201f9997df98`, `VO-85703cd3e2372ffb6509`, `VO-be7ee8383e989b214a82`, `VO-30a4c44a421cc90e23a2`, `VO-6bd91de95f0bb8ab4ce8`, `VO-82f809605d10cef51716`, `VO-afa8425c0ecdb9e9d3d8`, `VO-fd0f1c4858c4961584e0`, `VO-195afae65c44aa3dcf34`, `VO-5bb9225b782568f81af2`, `VO-672489b9771d8547e192`, `VO-f725b5aa29dfa9608556`, `VO-04c9121f3b5051968ee3`, `VO-3e6c7321565e6a6b5473`, `VO-ac289c2bf8b36b353ebb`

### Phase 3

- Gate ID: `GATE-phase-3`
- Required: yes
- Cumulative: yes
- Obligations: `VO-9f46c3eb28e58bd1fad2`, `VO-ccceee4bd62e391114c5`, `VO-a2c92a2c201f9997df98`, `VO-85703cd3e2372ffb6509`, `VO-be7ee8383e989b214a82`, `VO-30a4c44a421cc90e23a2`, `VO-6bd91de95f0bb8ab4ce8`, `VO-82f809605d10cef51716`, `VO-afa8425c0ecdb9e9d3d8`, `VO-fd0f1c4858c4961584e0`, `VO-195afae65c44aa3dcf34`, `VO-5bb9225b782568f81af2`, `VO-672489b9771d8547e192`, `VO-f725b5aa29dfa9608556`, `VO-04c9121f3b5051968ee3`, `VO-3e6c7321565e6a6b5473`, `VO-ac289c2bf8b36b353ebb`, `VO-c292a5c1db1b91cd8050`, `VO-0f4e897f6670173b34e4`, `VO-a8a3a9c61b1e7e884295`, `VO-779292f79fa9f59439bf`, `VO-89556224f3b7bbdb017c`, `VO-f5434170bc0fc81c39e5`, `VO-58d01e895466b225a4d1`, `VO-25f9fdd579584d745685`

### Phase 4

- Gate ID: `GATE-phase-4`
- Required: yes
- Cumulative: yes
- Obligations: `VO-9f46c3eb28e58bd1fad2`, `VO-ccceee4bd62e391114c5`, `VO-a2c92a2c201f9997df98`, `VO-85703cd3e2372ffb6509`, `VO-be7ee8383e989b214a82`, `VO-30a4c44a421cc90e23a2`, `VO-6bd91de95f0bb8ab4ce8`, `VO-82f809605d10cef51716`, `VO-afa8425c0ecdb9e9d3d8`, `VO-fd0f1c4858c4961584e0`, `VO-195afae65c44aa3dcf34`, `VO-5bb9225b782568f81af2`, `VO-672489b9771d8547e192`, `VO-f725b5aa29dfa9608556`, `VO-04c9121f3b5051968ee3`, `VO-3e6c7321565e6a6b5473`, `VO-ac289c2bf8b36b353ebb`, `VO-c292a5c1db1b91cd8050`, `VO-0f4e897f6670173b34e4`, `VO-a8a3a9c61b1e7e884295`, `VO-779292f79fa9f59439bf`, `VO-89556224f3b7bbdb017c`, `VO-f5434170bc0fc81c39e5`, `VO-58d01e895466b225a4d1`, `VO-25f9fdd579584d745685`, `VO-6ae9fe4bdc7236be4ddd`, `VO-d1482f465caa53b6427d`, `VO-2702a9dae6b3e7c4de5d`, `VO-d7dfdf45b4cbe519dd0a`, `VO-0f77de4d45b78effc56c`, `VO-44ab20617424b3d9b9d6`, `VO-1cb757c3e563d18c6a77`, `VO-1fd8ff0891858451b68c`, `VO-1ef6e0d0424a70793461`, `VO-41f0800bb583fb67a11a`, `VO-de6cfc1d65b0f4ba0c67`, `VO-15f4c9a51436a87e9c45`, `VO-43501490db482f1a1c59`, `VO-bdec9b841a44e6987924`, `VO-a499fa0552380fa18d51`, `VO-31bcca4c629d4495751e`, `VO-79d0bb68c7d504eb2755`, `VO-b4b933d8d0730c0c9944`, `VO-5139c3ce469e55e0ebc0`

### Phase 5

- Gate ID: `GATE-phase-5`
- Required: yes
- Cumulative: yes
- Obligations: `VO-9f46c3eb28e58bd1fad2`, `VO-ccceee4bd62e391114c5`, `VO-a2c92a2c201f9997df98`, `VO-85703cd3e2372ffb6509`, `VO-be7ee8383e989b214a82`, `VO-30a4c44a421cc90e23a2`, `VO-6bd91de95f0bb8ab4ce8`, `VO-82f809605d10cef51716`, `VO-afa8425c0ecdb9e9d3d8`, `VO-fd0f1c4858c4961584e0`, `VO-195afae65c44aa3dcf34`, `VO-5bb9225b782568f81af2`, `VO-672489b9771d8547e192`, `VO-f725b5aa29dfa9608556`, `VO-04c9121f3b5051968ee3`, `VO-3e6c7321565e6a6b5473`, `VO-ac289c2bf8b36b353ebb`, `VO-c292a5c1db1b91cd8050`, `VO-0f4e897f6670173b34e4`, `VO-a8a3a9c61b1e7e884295`, `VO-779292f79fa9f59439bf`, `VO-89556224f3b7bbdb017c`, `VO-f5434170bc0fc81c39e5`, `VO-58d01e895466b225a4d1`, `VO-25f9fdd579584d745685`, `VO-6ae9fe4bdc7236be4ddd`, `VO-d1482f465caa53b6427d`, `VO-2702a9dae6b3e7c4de5d`, `VO-d7dfdf45b4cbe519dd0a`, `VO-0f77de4d45b78effc56c`, `VO-44ab20617424b3d9b9d6`, `VO-1cb757c3e563d18c6a77`, `VO-1fd8ff0891858451b68c`, `VO-1ef6e0d0424a70793461`, `VO-41f0800bb583fb67a11a`, `VO-de6cfc1d65b0f4ba0c67`, `VO-15f4c9a51436a87e9c45`, `VO-43501490db482f1a1c59`, `VO-bdec9b841a44e6987924`, `VO-a499fa0552380fa18d51`, `VO-31bcca4c629d4495751e`, `VO-79d0bb68c7d504eb2755`, `VO-b4b933d8d0730c0c9944`, `VO-5139c3ce469e55e0ebc0`, `VO-fb27730c3b87691e83ad`, `VO-a9f22ad37d345e006bfe`, `VO-4c82072e941b140614f9`, `VO-7dddbf2c4016af0acd16`, `VO-1f8d441748c7bd01b0f8`, `VO-9e6be54b63f5644848fa`, `VO-b34481fc05c58ac0e4e3`, `VO-4554e0ee27ef3a00d04d`, `VO-c22c364bc3888e3aa8d3`, `VO-50090ba3f6512d5f8eff`, `VO-47eef71e39da0bedf9a5`, `VO-13ef51ff54617a759318`, `VO-c5bbeee56b0797caa9e8`, `VO-34344e579358253fdb30`

### Phase 6

- Gate ID: `GATE-phase-6`
- Required: yes
- Cumulative: yes
- Obligations: `VO-9f46c3eb28e58bd1fad2`, `VO-ccceee4bd62e391114c5`, `VO-a2c92a2c201f9997df98`, `VO-85703cd3e2372ffb6509`, `VO-be7ee8383e989b214a82`, `VO-30a4c44a421cc90e23a2`, `VO-6bd91de95f0bb8ab4ce8`, `VO-82f809605d10cef51716`, `VO-afa8425c0ecdb9e9d3d8`, `VO-fd0f1c4858c4961584e0`, `VO-195afae65c44aa3dcf34`, `VO-5bb9225b782568f81af2`, `VO-672489b9771d8547e192`, `VO-f725b5aa29dfa9608556`, `VO-04c9121f3b5051968ee3`, `VO-3e6c7321565e6a6b5473`, `VO-ac289c2bf8b36b353ebb`, `VO-c292a5c1db1b91cd8050`, `VO-0f4e897f6670173b34e4`, `VO-a8a3a9c61b1e7e884295`, `VO-779292f79fa9f59439bf`, `VO-89556224f3b7bbdb017c`, `VO-f5434170bc0fc81c39e5`, `VO-58d01e895466b225a4d1`, `VO-25f9fdd579584d745685`, `VO-6ae9fe4bdc7236be4ddd`, `VO-d1482f465caa53b6427d`, `VO-2702a9dae6b3e7c4de5d`, `VO-d7dfdf45b4cbe519dd0a`, `VO-0f77de4d45b78effc56c`, `VO-44ab20617424b3d9b9d6`, `VO-1cb757c3e563d18c6a77`, `VO-1fd8ff0891858451b68c`, `VO-1ef6e0d0424a70793461`, `VO-41f0800bb583fb67a11a`, `VO-de6cfc1d65b0f4ba0c67`, `VO-15f4c9a51436a87e9c45`, `VO-43501490db482f1a1c59`, `VO-bdec9b841a44e6987924`, `VO-a499fa0552380fa18d51`, `VO-31bcca4c629d4495751e`, `VO-79d0bb68c7d504eb2755`, `VO-b4b933d8d0730c0c9944`, `VO-5139c3ce469e55e0ebc0`, `VO-fb27730c3b87691e83ad`, `VO-a9f22ad37d345e006bfe`, `VO-4c82072e941b140614f9`, `VO-7dddbf2c4016af0acd16`, `VO-1f8d441748c7bd01b0f8`, `VO-9e6be54b63f5644848fa`, `VO-b34481fc05c58ac0e4e3`, `VO-4554e0ee27ef3a00d04d`, `VO-c22c364bc3888e3aa8d3`, `VO-50090ba3f6512d5f8eff`, `VO-47eef71e39da0bedf9a5`, `VO-13ef51ff54617a759318`, `VO-c5bbeee56b0797caa9e8`, `VO-34344e579358253fdb30`, `VO-b5245cfe8692376af119`, `VO-db2598e32f6f21e1d55d`, `VO-8830b3bcffcedacf6d51`, `VO-e03b5ef3e6babf111591`, `VO-e8d65a5d364eebb383b4`, `VO-6bd4e120341dde856299`, `VO-00e3c9a00dcc564ab44f`, `VO-8fd525d0c496af1fa4b5`, `VO-ecff1cc23cd30ed63dd2`, `VO-7f9e51b7961d6fe60567`, `VO-056bd8761b973f3ad8bc`

### Phase 7

- Gate ID: `GATE-phase-7`
- Required: yes
- Cumulative: yes
- Obligations: `VO-9f46c3eb28e58bd1fad2`, `VO-ccceee4bd62e391114c5`, `VO-a2c92a2c201f9997df98`, `VO-85703cd3e2372ffb6509`, `VO-be7ee8383e989b214a82`, `VO-30a4c44a421cc90e23a2`, `VO-6bd91de95f0bb8ab4ce8`, `VO-82f809605d10cef51716`, `VO-afa8425c0ecdb9e9d3d8`, `VO-fd0f1c4858c4961584e0`, `VO-195afae65c44aa3dcf34`, `VO-5bb9225b782568f81af2`, `VO-672489b9771d8547e192`, `VO-f725b5aa29dfa9608556`, `VO-04c9121f3b5051968ee3`, `VO-3e6c7321565e6a6b5473`, `VO-ac289c2bf8b36b353ebb`, `VO-c292a5c1db1b91cd8050`, `VO-0f4e897f6670173b34e4`, `VO-a8a3a9c61b1e7e884295`, `VO-779292f79fa9f59439bf`, `VO-89556224f3b7bbdb017c`, `VO-f5434170bc0fc81c39e5`, `VO-58d01e895466b225a4d1`, `VO-25f9fdd579584d745685`, `VO-6ae9fe4bdc7236be4ddd`, `VO-d1482f465caa53b6427d`, `VO-2702a9dae6b3e7c4de5d`, `VO-d7dfdf45b4cbe519dd0a`, `VO-0f77de4d45b78effc56c`, `VO-44ab20617424b3d9b9d6`, `VO-1cb757c3e563d18c6a77`, `VO-1fd8ff0891858451b68c`, `VO-1ef6e0d0424a70793461`, `VO-41f0800bb583fb67a11a`, `VO-de6cfc1d65b0f4ba0c67`, `VO-15f4c9a51436a87e9c45`, `VO-43501490db482f1a1c59`, `VO-bdec9b841a44e6987924`, `VO-a499fa0552380fa18d51`, `VO-31bcca4c629d4495751e`, `VO-79d0bb68c7d504eb2755`, `VO-b4b933d8d0730c0c9944`, `VO-5139c3ce469e55e0ebc0`, `VO-fb27730c3b87691e83ad`, `VO-a9f22ad37d345e006bfe`, `VO-4c82072e941b140614f9`, `VO-7dddbf2c4016af0acd16`, `VO-1f8d441748c7bd01b0f8`, `VO-9e6be54b63f5644848fa`, `VO-b34481fc05c58ac0e4e3`, `VO-4554e0ee27ef3a00d04d`, `VO-c22c364bc3888e3aa8d3`, `VO-50090ba3f6512d5f8eff`, `VO-47eef71e39da0bedf9a5`, `VO-13ef51ff54617a759318`, `VO-c5bbeee56b0797caa9e8`, `VO-34344e579358253fdb30`, `VO-b5245cfe8692376af119`, `VO-db2598e32f6f21e1d55d`, `VO-8830b3bcffcedacf6d51`, `VO-e03b5ef3e6babf111591`, `VO-e8d65a5d364eebb383b4`, `VO-6bd4e120341dde856299`, `VO-00e3c9a00dcc564ab44f`, `VO-8fd525d0c496af1fa4b5`, `VO-ecff1cc23cd30ed63dd2`, `VO-7f9e51b7961d6fe60567`, `VO-056bd8761b973f3ad8bc`, `VO-4cbb3fd9287b43a8c568`, `VO-7772a592df54868fd695`, `VO-acde1320264805533177`, `VO-40f5129c9a6eb2dba795`, `VO-702987d2b40f218ffef9`, `VO-8e57358ced826d89be85`, `VO-2a103a2314a25cb8a5d3`, `VO-1010f91be22c528c4aa2`, `VO-c69fb81dc51f49ba14c5`, `VO-ee9cae08517d5346a12e`, `VO-5c3e24deb467a61f7375`

### Phase 8

- Gate ID: `GATE-phase-8`
- Required: yes
- Cumulative: yes
- Obligations: `VO-9f46c3eb28e58bd1fad2`, `VO-ccceee4bd62e391114c5`, `VO-a2c92a2c201f9997df98`, `VO-85703cd3e2372ffb6509`, `VO-be7ee8383e989b214a82`, `VO-30a4c44a421cc90e23a2`, `VO-6bd91de95f0bb8ab4ce8`, `VO-82f809605d10cef51716`, `VO-afa8425c0ecdb9e9d3d8`, `VO-fd0f1c4858c4961584e0`, `VO-195afae65c44aa3dcf34`, `VO-5bb9225b782568f81af2`, `VO-672489b9771d8547e192`, `VO-f725b5aa29dfa9608556`, `VO-04c9121f3b5051968ee3`, `VO-3e6c7321565e6a6b5473`, `VO-ac289c2bf8b36b353ebb`, `VO-c292a5c1db1b91cd8050`, `VO-0f4e897f6670173b34e4`, `VO-a8a3a9c61b1e7e884295`, `VO-779292f79fa9f59439bf`, `VO-89556224f3b7bbdb017c`, `VO-f5434170bc0fc81c39e5`, `VO-58d01e895466b225a4d1`, `VO-25f9fdd579584d745685`, `VO-6ae9fe4bdc7236be4ddd`, `VO-d1482f465caa53b6427d`, `VO-2702a9dae6b3e7c4de5d`, `VO-d7dfdf45b4cbe519dd0a`, `VO-0f77de4d45b78effc56c`, `VO-44ab20617424b3d9b9d6`, `VO-1cb757c3e563d18c6a77`, `VO-1fd8ff0891858451b68c`, `VO-1ef6e0d0424a70793461`, `VO-41f0800bb583fb67a11a`, `VO-de6cfc1d65b0f4ba0c67`, `VO-15f4c9a51436a87e9c45`, `VO-43501490db482f1a1c59`, `VO-bdec9b841a44e6987924`, `VO-a499fa0552380fa18d51`, `VO-31bcca4c629d4495751e`, `VO-79d0bb68c7d504eb2755`, `VO-b4b933d8d0730c0c9944`, `VO-5139c3ce469e55e0ebc0`, `VO-fb27730c3b87691e83ad`, `VO-a9f22ad37d345e006bfe`, `VO-4c82072e941b140614f9`, `VO-7dddbf2c4016af0acd16`, `VO-1f8d441748c7bd01b0f8`, `VO-9e6be54b63f5644848fa`, `VO-b34481fc05c58ac0e4e3`, `VO-4554e0ee27ef3a00d04d`, `VO-c22c364bc3888e3aa8d3`, `VO-50090ba3f6512d5f8eff`, `VO-47eef71e39da0bedf9a5`, `VO-13ef51ff54617a759318`, `VO-c5bbeee56b0797caa9e8`, `VO-34344e579358253fdb30`, `VO-b5245cfe8692376af119`, `VO-db2598e32f6f21e1d55d`, `VO-8830b3bcffcedacf6d51`, `VO-e03b5ef3e6babf111591`, `VO-e8d65a5d364eebb383b4`, `VO-6bd4e120341dde856299`, `VO-00e3c9a00dcc564ab44f`, `VO-8fd525d0c496af1fa4b5`, `VO-ecff1cc23cd30ed63dd2`, `VO-7f9e51b7961d6fe60567`, `VO-056bd8761b973f3ad8bc`, `VO-4cbb3fd9287b43a8c568`, `VO-7772a592df54868fd695`, `VO-acde1320264805533177`, `VO-40f5129c9a6eb2dba795`, `VO-702987d2b40f218ffef9`, `VO-8e57358ced826d89be85`, `VO-2a103a2314a25cb8a5d3`, `VO-1010f91be22c528c4aa2`, `VO-c69fb81dc51f49ba14c5`, `VO-ee9cae08517d5346a12e`, `VO-5c3e24deb467a61f7375`, `VO-2ac8f48fdffd009e097d`, `VO-ae7e6709fee471285ba5`, `VO-96f56366d7bd57aa6e89`, `VO-e65eb8b20d3123faf0f1`, `VO-b84282c3534000a4f8ed`, `VO-f14678dc981207cf35e9`, `VO-28f8a9a2cafc76e72ca7`, `VO-d8434673434071887d85`, `VO-3a22a7a89d8faf5a6abd`, `VO-83dcb5e1f8f2e7bb8c36`

### Phase 9

- Gate ID: `GATE-phase-9`
- Required: yes
- Cumulative: yes
- Obligations: `VO-9f46c3eb28e58bd1fad2`, `VO-ccceee4bd62e391114c5`, `VO-a2c92a2c201f9997df98`, `VO-85703cd3e2372ffb6509`, `VO-be7ee8383e989b214a82`, `VO-30a4c44a421cc90e23a2`, `VO-6bd91de95f0bb8ab4ce8`, `VO-82f809605d10cef51716`, `VO-afa8425c0ecdb9e9d3d8`, `VO-fd0f1c4858c4961584e0`, `VO-195afae65c44aa3dcf34`, `VO-5bb9225b782568f81af2`, `VO-672489b9771d8547e192`, `VO-f725b5aa29dfa9608556`, `VO-04c9121f3b5051968ee3`, `VO-3e6c7321565e6a6b5473`, `VO-ac289c2bf8b36b353ebb`, `VO-c292a5c1db1b91cd8050`, `VO-0f4e897f6670173b34e4`, `VO-a8a3a9c61b1e7e884295`, `VO-779292f79fa9f59439bf`, `VO-89556224f3b7bbdb017c`, `VO-f5434170bc0fc81c39e5`, `VO-58d01e895466b225a4d1`, `VO-25f9fdd579584d745685`, `VO-6ae9fe4bdc7236be4ddd`, `VO-d1482f465caa53b6427d`, `VO-2702a9dae6b3e7c4de5d`, `VO-d7dfdf45b4cbe519dd0a`, `VO-0f77de4d45b78effc56c`, `VO-44ab20617424b3d9b9d6`, `VO-1cb757c3e563d18c6a77`, `VO-1fd8ff0891858451b68c`, `VO-1ef6e0d0424a70793461`, `VO-41f0800bb583fb67a11a`, `VO-de6cfc1d65b0f4ba0c67`, `VO-15f4c9a51436a87e9c45`, `VO-43501490db482f1a1c59`, `VO-bdec9b841a44e6987924`, `VO-a499fa0552380fa18d51`, `VO-31bcca4c629d4495751e`, `VO-79d0bb68c7d504eb2755`, `VO-b4b933d8d0730c0c9944`, `VO-5139c3ce469e55e0ebc0`, `VO-fb27730c3b87691e83ad`, `VO-a9f22ad37d345e006bfe`, `VO-4c82072e941b140614f9`, `VO-7dddbf2c4016af0acd16`, `VO-1f8d441748c7bd01b0f8`, `VO-9e6be54b63f5644848fa`, `VO-b34481fc05c58ac0e4e3`, `VO-4554e0ee27ef3a00d04d`, `VO-c22c364bc3888e3aa8d3`, `VO-50090ba3f6512d5f8eff`, `VO-47eef71e39da0bedf9a5`, `VO-13ef51ff54617a759318`, `VO-c5bbeee56b0797caa9e8`, `VO-34344e579358253fdb30`, `VO-b5245cfe8692376af119`, `VO-db2598e32f6f21e1d55d`, `VO-8830b3bcffcedacf6d51`, `VO-e03b5ef3e6babf111591`, `VO-e8d65a5d364eebb383b4`, `VO-6bd4e120341dde856299`, `VO-00e3c9a00dcc564ab44f`, `VO-8fd525d0c496af1fa4b5`, `VO-ecff1cc23cd30ed63dd2`, `VO-7f9e51b7961d6fe60567`, `VO-056bd8761b973f3ad8bc`, `VO-4cbb3fd9287b43a8c568`, `VO-7772a592df54868fd695`, `VO-acde1320264805533177`, `VO-40f5129c9a6eb2dba795`, `VO-702987d2b40f218ffef9`, `VO-8e57358ced826d89be85`, `VO-2a103a2314a25cb8a5d3`, `VO-1010f91be22c528c4aa2`, `VO-c69fb81dc51f49ba14c5`, `VO-ee9cae08517d5346a12e`, `VO-5c3e24deb467a61f7375`, `VO-2ac8f48fdffd009e097d`, `VO-ae7e6709fee471285ba5`, `VO-96f56366d7bd57aa6e89`, `VO-e65eb8b20d3123faf0f1`, `VO-b84282c3534000a4f8ed`, `VO-f14678dc981207cf35e9`, `VO-28f8a9a2cafc76e72ca7`, `VO-d8434673434071887d85`, `VO-3a22a7a89d8faf5a6abd`, `VO-83dcb5e1f8f2e7bb8c36`, `VO-12800b0da6e5f79c8841`, `VO-49a37696182d233fcca0`, `VO-6c7a5cc860e03427822c`, `VO-7b4ccf19a4c734d7e2a6`, `VO-67a800f5260a7bc02738`, `VO-901da35e345226f6cc19`, `VO-cc4f6342659867995225`, `VO-190af6c74d36bf615f38`, `VO-8b87ffb02209868f327f`, `VO-1d7c0b1827ecd6108f49`, `VO-5f862404d000455fa6e8`

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
