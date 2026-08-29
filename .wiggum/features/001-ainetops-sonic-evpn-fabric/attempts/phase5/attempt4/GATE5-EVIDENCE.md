# Phase 5 — Default fabric and service data plane (US2, US3, US5)

This evidence addresses every acceptance criterion with independently observable artifacts and anchored proof slices. Cited files are relative to the workdir root.

## T041a Build and deploy SRv6 controller; verify Pod/Service/probes/RBAC; gate SRv6 tests on health

- Built and loaded the SRv6 controller image, deployed Deployment and Service via T023 manifests; Deployment specifies probes and ServiceAccount:
  - Deployment/Service manifest: deploy/ainetops/manifests/srv6-controller.yaml
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.srv6-controller.yaml.probe-service.lines.txt (lines show name, labels, ports, readinessProbe, livenessProbe, and Service selector)
  - Running state observed via independent kubectl get snapshot:
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-ainetops-system.txt (shows deployment.apps/ainetops-srv6-controller, pod, and service)
- RBAC corrected to bind the exact ServiceAccount used by the Deployment:
  - Controller SA: config/rbac/service_account.yaml (ServiceAccount name: "ainetops-srv6-controller")
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.service_account.srv6.lines.txt (contains "name: ainetops-srv6-controller")
  - ClusterRole with SRv6Service and events permissions: config/rbac/cluster_role.yaml (name: "ainetops-srv6-controller")
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.cluster_role.yaml.slice.txt (contains "name: ainetops-srv6-controller")
  - ClusterRoleBinding subjects corrected to ServiceAccount ainetops-srv6-controller:
    - deploy/rbac/srv6-crd-rbac.yaml (ClusterRoleBinding name: ainetops-srv6-controller-crd, subject ServiceAccount name: ainetops-srv6-controller)
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.srv6-crd-rbac.yaml.slice.txt (shows subjects -> name: ainetops-srv6-controller)
    - Core ClusterRoleBinding: config/rbac/cluster_role_binding.yaml (name: ainetops-srv6-controller, subject ServiceAccount name: ainetops-srv6-controller)
      - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.cluster_role_binding.yaml.proof.txt
- Health gate enforced: scripts/provision.sh now fails on rollout failure; SRv6 tests do not proceed until the controller is Ready.
  - File: scripts/provision.sh
  - Proof slice (before/after and final lines with no "|| true"): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.controllers.rollout.before.after.txt and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.controllers.rollout.slice.txt

## T042 [US3] Apply default Kubenet Network and reconcile underlay/EVPN/VTEPs

- Default fabric Network manifest applied by scripts/provision.sh; defines dual-stack underlay, loopbacks, BGP, EVPN address families, VXLAN VTEP source, and leaf VTEP attachments.
  - File: deploy/kubenet/networks/default.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.default.yaml.slice.txt
- Independent kubectl get proof shows created Network objects including default-fabric and tenants:
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-kubenet-networks.txt

## T043 [US3] Verify underlay/EVPN sessions, loopback/waypoint reachability, and FR-004 negative

- Implemented verification script with gNMI assertions and negative checks against spines.
  - File: tests/integration/fabric_verify.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.fabric_verify.sh.lines.txt (shows BGP session-state, EVPN AF enabled, EVPN route-table GETs, loopback reachability keyword, waypoint traceroute, and negative spine VXLAN/VRF assertions)

## T044 [P] [US1] Bridged L2 tenant example

- File: deploy/kubenet/networks/tenants/l2-bridged.yaml
- Contains two cross-leaf attachments, VLAN, L2VNI, and RTs

## T045 [P] [US1] Routed L3 tenant example

- File: deploy/kubenet/networks/tenants/l3-routed.yaml
- Contains VRF with L3VNI, RD/RT, and prefixes

## T046 [P] [US1] Symmetric-IRB example

- File: deploy/kubenet/networks/tenants/irb-symmetric.yaml
- Contains L2/L3 VNIs, gateway addresses, and two isolated VRFs

## T047 [US3] EVPN client traffic tests

- Implemented cross-leaf L2, intra-VRF L3/IRB, and inter-VRF isolation.
  - File: tests/integration/evpn_traffic.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_traffic.sh.lines.txt

## T047a [US3] MTU and ECMP tests

- Implemented maximum effective MTU and ECMP hashing checks using interface counters.
  - File: tests/integration/mtu_ecmp.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.mtu_ecmp.sh.lines.txt

## T047b [US5] SRv6 capture and counter tests

- Implemented capture of outer IPv6/SRH with ordered SIDs, decap VRF verification, and MySID counter increment assertions.
  - File: tests/integration/srv6_capture_counters.sh
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.srv6_capture_counters.sh.lines.txt (shows tcpdump capture, sha256 of pcap, SID_LIST fetch, ordered SID verification loop, BEHAVIORS End.DT46 VRF check, and MySID counters)
    - Durable pcap identity proof file exists from a run: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.pcap.sha256
  - Ordered SID verification is strict: test fails if expected SIDs cannot be discovered; no fallback acceptance path remains.
    - Implementation change proof: same lines file above shows removal of fallback and error on missing expected SID list.

## T047c [US5] Failover and operator-directed path-change tests

- Implemented primary failure (containerlab link down), asserted SRv6PathDown alert, patched spec.pathPolicy.selectedPath=alternate, and verified recovery and POLICY reflects the alternate path without telemetry-driven mutation.
  - File: tests/integration/srv6_failover_path_change.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.srv6_failover_path_change.sh.lines.txt

## T048 [US2] Repeat-apply proof (idempotence)

- Implemented repeat-apply proof that unchanged intent produces zero SDC spec writes and zero gNMI Sets across fabric, tenants, and SRv6.
  - File: tests/integration/idempotence.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.idempotence.sh.lines.txt
  - Generated artifacts from a run:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/idempotence.config-hashes.before.txt and .../after.txt
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/idempotence.gnmi-events.before.txt and .../after.txt

## T049 [US2] Partial failure/recovery, provider restart mid-transaction, invalid-YANG, partial SRv6 programming, false Ready prohibition

- File: tests/integration/failure_recovery_invalid_yang.sh
- Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.failure_recovery_invalid_yang.sh.lines.txt
- Generated artifacts include:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/partial-failure.targets.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/invalid-yang.apply.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6-ready-after-partial.txt

## T050 [US2] Drift restoration and unmanaged-path preservation

- File: tests/integration/drift_preservation.sh
- Proof artifacts: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/drift.bgp-as.before.txt, drift.bgp-as.after.txt, and drift.if-desc.after.txt

## T051 [US2] Update and delete lifecycle (effect-witness)

- Implemented update/delete survivability; generated durable, independently readable artifacts from a run showing:
  - default-fabric still present after update and after delete
    - Files: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.default-fabric.txt and delete.default-fabric.txt
  - Full SDC Config set snapshot after update
    - File: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.sdc-configs.after.txt
  - SRv6-owned SDC Config count before/after delete
    - Files: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.count.before.txt and .../after.txt
  - Source script: tests/integration/update_delete_survivability.sh (anchors show exact output paths)
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.update_delete_survivability.sh.lines.txt

## Additional grounding requested by critic (now present)

- config/samples/ainetops_v1alpha1_srv6service.yaml
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.sdc-configs.after.txt
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.count.before.txt
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.count.after.txt
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.pcap.sha256

