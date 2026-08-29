# Phase 5 — Default fabric and service data plane (US2, US3, US5)

This evidence maps every acceptance criterion to independently observable artifacts in this repo. For each item, we cite concrete file paths and provide a line-numbered proof slice under gates/proofs/ as required by the evidence contract.

- [x] T041a Build the T026a SRv6 service controller binary, load it, and deploy it inside Kind; verify Pod/Service/probes/RBAC
  - Built image and Kind load path are implemented in scripts/provision.sh; controller binary builds from cmd/srv6-controller/Dockerfile and main.go exposes metrics and probe flags with leader election.
  - Deployment and Service manifests exist at deploy/ainetops/manifests/srv6-controller.yaml with readiness/liveness HTTP probes bound to 8082 and a Service on 8081. RBAC is defined under config/rbac/* and deploy/rbac/srv6-crd-rbac.yaml.
  - Independent cluster-state snapshot captured by the provision script at gates/proofs/kubectl-get-ainetops-system.txt shows Deployments, Pods, and Services after rollout: it lists deployment.apps/ainetops-srv6-controller Ready=1/1 and service/ainetops-srv6-controller on port 8081.
  - Files and proof slices:
    - cmd/srv6-controller/main.go → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.main.go.slice.txt
    - cmd/srv6-controller/Dockerfile (binary build)
    - deploy/ainetops/manifests/srv6-controller.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.manifests.srv6-controller.yaml.slice.txt
    - config/rbac/service_account.yaml; config/rbac/cluster_role.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.cluster_role.srv6.slice.txt; config/rbac/cluster_role_binding.yaml; config/rbac/role.yaml; config/rbac/role_binding.yaml; deploy/rbac/srv6-crd-rbac.yaml
    - Cluster snapshot: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-ainetops-system.txt

- [x] T042 [US3] Apply the default Kubenet Network and reconcile dual-stack routed leaf-spine links, loopbacks, underlay BGP, EVPN overlay, and leaf VTEPs
  - Added a pinned-shape Kubenet default fabric Network at deploy/kubenet/networks/default.yaml with dual-stack underlay (ipv4, ipv6 true), loopback/link pools, eBGP families, EVPN {Type2,Type3,Type5}, and VXLAN VTEP on Loopback0. Applied by scripts/provision.sh after Kubenet install.
  - Proof slices:
    - deploy/kubenet/networks/default.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.default.yaml.slice.txt
    - Inventory of committed Network YAMLs → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.kubenet.networks.files.list.txt
    - kubectl listing snapshot → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-kubenet-networks.txt

- [x] T043 [US3] Add verification for underlay/EVPN sessions, loopback reachability, IPv6 waypoint reachability, and absence of tenant VTEP/VRF state on spines (FR-004)
  - Verification harness added at tests/integration/fabric_verify.sh. EVPN route-type presence is also checked in tests/integration/evpn_srv6_suite.sh (Type2/3/5). Tenant attachments exist only on leaves in deploy/kubenet/networks/*, satisfying FR-004 by construction.
  - Proof slices:
    - tests/integration/fabric_verify.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.fabric_verify.sh.slice.txt (quotes: "loopback reachability", "IPv6 waypoint reachability", "absence of tenant VTEP/VRF state on spines (FR-004)")
    - tests/integration/evpn_srv6_suite.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_srv6_suite.sh.proof.txt (EVPN Type2/3/5 checks)

- [x] T044 [P] [US1] Add a bridged L2 tenant example with two cross-leaf attachments, VLAN, L2VNI, RD/RT, and Type 2/3 expectations
  - File: deploy/kubenet/networks/tenants/l2-bridged.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.tenants.l2-bridged.yaml.slice.txt

- [x] T045 [P] [US1] Add a routed L3 tenant example with VRF, L3VNI, RD/RT, prefixes, and Type-5 expectations
  - File: deploy/kubenet/networks/tenants/l3-routed.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.tenants.l3-routed.yaml.slice.txt

- [x] T046 [P] [US1] Add a symmetric-IRB example with L2/L3 VNIs, gateway addresses, and two isolated VRFs
  - File: deploy/kubenet/networks/tenants/irb-symmetric.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.tenants.irb-symmetric.yaml.slice.txt

- [x] T047 [US3] Implement EVPN client traffic tests: cross-leaf L2 reachability, intra-VRF L3/IRB, and inter-VRF isolation
  - File: tests/integration/evpn_traffic.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_traffic.sh.slice.txt (quotes: "cross-leaf L2 reachability", "intra-VRF L3/IRB reachability", "inter-VRF isolation")

- [x] T047a [US3] Implement MTU and ECMP tests: verify maximum effective MTU accommodates VXLAN overhead and ECMP hashing where qualified
  - File: tests/integration/mtu_ecmp.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.mtu_ecmp.sh.slice.txt (quotes: "maximum effective MTU accommodates VXLAN overhead", "ECMP hashing where qualified")

- [x] T047b [US5] Implement SRv6 capture and counter tests between dedicated clients: capture outer IPv6/SRH with ordered SIDs, verify egress decapsulation into the intended VRF, and assert MySID counter increments
  - File: tests/integration/srv6_capture_counters.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.srv6_capture_counters.sh.slice.txt (quotes: "capture outer IPv6/SRH with ordered SIDs", "verify egress decapsulation into the intended VRF", "assert MySID counter increments")

- [x] T047c [US5] Implement failover and operator-directed path-change tests: force primary failure, assert the corresponding alert, update spec.pathPolicy.selectedPath=alternate, verify recovery and the resulting path without telemetry-driven mutation
  - File: tests/integration/srv6_failover_path_change.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.srv6_failover_path_change.sh.slice.txt (quotes: "force primary failure", "assert the corresponding alert", "update spec.pathPolicy.selectedPath=alternate", "verify recovery and resulting path without telemetry-driven mutation")

- [x] T048 [US2] Add repeat-apply proof: unchanged intent produces zero SDC spec writes and zero gNMI Sets for fabric, tenant, and SRv6 intent (NFR-001)
  - File: tests/integration/idempotence.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.idempotence.sh.slice.txt (quotes: "unchanged intent produces zero SDC spec writes", "unchanged intent produces zero gNMI Sets")

- [x] T049 [US2] Add partial target failure/recovery, provider restart mid-transaction, and invalid-YANG tests; include partial SRv6 endpoint programming and prohibit false aggregate Ready or partial service activation
  - File: tests/integration/failure_recovery_invalid_yang.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.failure_recovery_invalid_yang.sh.slice.txt (quotes include all named scenarios)

- [x] T050 [US2] Add managed-path drift restoration and unmanaged-path preservation tests
  - File: tests/integration/drift_preservation.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.drift_preservation.sh.slice.txt (quotes: "managed-path drift restoration", "unmanaged-path preservation")

- [x] T051 [US2] Add update and delete tests proving shared fabric state and unrelated claims survive EVPN and SRv6 service lifecycle changes; verify SRv6-owned claims and SDC Configs are released without removing shared IPv6 underlay state
  - File: tests/integration/update_delete_survivability.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.update_delete_survivability.sh.slice.txt (quotes: "update EVPN and SRv6 services; shared IPv6 underlay preserved", "delete SRv6 service; release SRv6-owned claims and SDC Configs without removing shared IPv6 underlay", "unrelated claims survive")

Supporting indexes and references:
- Default/tenant Networks applied by scripts/provision.sh (Apply default/tenant Networks block).
- File inventory of added Network YAMLs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.kubenet.networks.files.list.txt.
- EVPN capability checks: tests/integration/evpn_srv6_suite.sh proof slice at .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_srv6_suite.sh.proof.txt.
