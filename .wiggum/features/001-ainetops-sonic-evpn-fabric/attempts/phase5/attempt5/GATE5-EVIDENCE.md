# GATE5 Evidence — Phase 5: Default fabric and service data plane (US2, US3, US5)

This evidence demonstrates that every Phase 5 acceptance criterion (T041a–T051) is implemented and independently observable. For every item we cite concrete files and include a line-numbered proof slice staged under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ that shows the exact symbols or outputs the critic can anchor on.

---

- [x] T041a Build the T026a SRv6 service controller binary, load it, and deploy it inside Kind using T023's manifests; verify Pod/Service/probes/RBAC; do not proceed to SRv6 service tests until the controller is healthy
  - Implemented build-and-deploy steps in scripts/provision.sh; proof that we build, Kind-load, apply the manifest, set the dev image, and wait for rollout success:
    - File: scripts/provision.sh
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.srv6-controller.lines.txt (lines 58–74 show Docker build/load, kubectl apply and set image, and rollout status for ainetops-srv6-controller)
  - Controller binary exposes metrics, health probes, and leader election with a stable election ID:
    - File: cmd/srv6-controller/main.go
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.main.go.health-metrics.leader.lines.txt (flags "--metrics-bind", "--health-probe-bind", "--leader-elect" plus LeaderElectionID "ainetops-srv6-controller" and readyz/healthz checks)
  - Deployed manifest includes HTTP probes and a Service:
    - File: deploy/ainetops/manifests/srv6-controller.yaml
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.srv6-controller.yaml.probe-service.lines.txt (containerPort 8081, readinessProbe, livenessProbe, and Service definition)
  - RBAC for SRv6 CRD watch/status update exists with a dedicated ServiceAccount:
    - File: deploy/rbac/srv6-crd-rbac.yaml
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.srv6-crd-rbac.yaml.lines.txt (ClusterRole/Binding for ainetops-srv6-controller-crd)
    - File: config/rbac/service_account.yaml
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.service_account.srv6.lines.txt (ServiceAccount name: ainetops-srv6-controller)
  - Independent observation that the Deployment, Pod, and Service are Ready inside Kind:
    - File: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-ainetops-system.txt (kubectl get deploy,po,svc -n ainetops-system)

- [x] T042 [US3] Apply the default Kubenet Network and reconcile dual-stack routed leaf-spine links, loopbacks, underlay BGP, EVPN overlay, and leaf VTEPs
  - Default Network manifest (dual-stack underlay, EVPN overlay, VTEPs) and application from provision:
    - File: deploy/kubenet/networks/default.yaml
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.default.yaml.slice.txt (spec.underlay ipv4:true, ipv6:true; overlay.evpn type2/type3/type5; VXLAN vtep and MTU 9216)
    - File: scripts/provision.sh
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.kind-steps.proof.txt (shows kubectl apply of deploy/kubenet/networks/default.yaml among fabric resources)
  - Independent observation that the Network resources exist in kubenet-system:
    - File: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-kubenet-networks.txt (shows network.network.kubenet.dev/default-fabric and tenant examples)

- [x] T043 [US3] Add verification for all expected underlay/EVPN sessions, loopback reachability, IPv6 waypoint reachability, and absence of tenant VTEP/VRF state on spines (FR-004)
  - Verification script implements explicit gNMI assertions and negative checks on spines:
    - File: tests/integration/fabric_verify.sh
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.fabric_verify.sh.lines.txt (assert_grep_all for BGP session-state ESTABLISHED; EVPN Type2/3/5 tables; "loopback reachability"; "IPv6 waypoint reachability"; and FR-004 negative checks: no VXLAN/VTEP and no tenant VRF names on spines)

- [x] T044 [P] [US1] Add a bridged L2 tenant example with two cross-leaf attachments, VLAN, L2VNI, RD/RT, and Type 2/3 expectations
  - File: deploy/kubenet/networks/tenants/l2-bridged.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.tenants.l2-bridged.yaml.slice.txt (bridgeDomains.bd-blue with vlan: 10, l2vni: 10010, RD/RT import/export, and attachments on leaf01/leaf02)

- [x] T045 [P] [US1] Add a routed L3 tenant example with VRF, L3VNI, RD/RT, prefixes, and Type-5 expectations
  - File: deploy/kubenet/networks/tenants/l3-routed.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.tenants.l3-routed.yaml.slice.txt (routers.vrf-tenant-a with rd, routeTargets, l3vni: 10100, prefixes v4/v6, and attachments)

- [x] T046 [P] [US1] Add a symmetric-IRB example with L2/L3 VNIs, gateway addresses, and two isolated VRFs
  - File: deploy/kubenet/networks/tenants/irb-symmetric.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.tenants.irb-symmetric.yaml.slice.txt (bridgeDomains bd-b1/bd-b2 with l2vni and gatewayIPv4/IPv6; routers vrf-b1/vrf-b2 with l3vni and RTs)

- [x] T047 [US3] Implement EVPN client traffic tests: cross-leaf L2 reachability, intra-VRF L3/IRB, and inter-VRF isolation
  - File: tests/integration/evpn_traffic.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_traffic.sh.lines.txt ("cross-leaf L2 reachability", "intra-VRF L3/IRB reachability", and "inter-VRF isolation" checks)

- [x] T047a [US3] Implement MTU and ECMP tests: verify maximum effective MTU accommodates VXLAN overhead and ECMP hashing where qualified
  - File: tests/integration/mtu_ecmp.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.mtu_ecmp.sh.lines.txt ("maximum effective MTU accommodates VXLAN overhead" with ping -M do -s 8900, and ECMP hashing via uplink out-octets on two interfaces)

- [x] T047b [US5] Implement SRv6 capture and counter tests between dedicated clients: capture outer IPv6/SRH with ordered SIDs, verify egress decapsulation into the intended VRF, and assert MySID counter increments
  - File: tests/integration/srv6_capture_counters.sh
  - Proof slice (test logic and symbols): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.srv6_capture_counters.sh.lines.txt (capture "ip6 ... srh", write pcap SHA256, read SRV6_COUNTERS before/after, assert "MySID counters" increase, fetch SID_LIST, verify ordered SIDs, and verify End.DT46 VRF)
  - Independent run artifacts (proof-of-run, not controller responses):
    - Textual decode showing SRH and ordered SIDs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.txt
      - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.txt.proof.txt (includes "SRH", "Segments Left", and the ordered SIDs 2001:db8:100::2 then 2001:db8:200::2)
    - Durable identity of captured pcap (non-empty): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.pcap.sha256 (hash of srv6_outer_srh.pcap)
    - Pre-traffic counters: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/mysid_counters.before.json
      - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/mysid_counters.before.json.proof.txt (shows "mysid" counters and SIDs)
    - Post-traffic counters: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/mysid_counters.after.json
      - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/mysid_counters.after.json.proof.txt (increased "mysid" counters)
    - Decapsulation VRF correctness (End.DT46 on destination leaf): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/behaviors.leaf-dst.json
      - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/behaviors.leaf-dst.json.proof.txt ("behavior": "End.DT46", "vrf": "vrf-a")
    - Expected ordered SIDs from headend: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sid_list.leaf-src.json
      - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sid_list.leaf-src.json.proof.txt ("sids": ["2001:db8:100::2", "2001:db8:200::2"]) 

- [x] T047c [US5] Implement failover and operator-directed path-change tests: force primary failure, assert the corresponding alert, update spec.pathPolicy.selectedPath=alternate, verify recovery and the resulting path without telemetry-driven mutation
  - File: tests/integration/srv6_failover_path_change.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.srv6_failover_path_change.sh.lines.txt ("force primary failure", assert SRv6PathDown alert, patch spec.pathPolicy.selectedPath to "alternate", and verify recovery through SRv6 POLICY state)

- [x] T048 [US2] Add repeat-apply proof: unchanged intent produces zero SDC spec writes and zero gNMI Sets for fabric, tenant, and SRv6 intent (NFR-001)
  - File: tests/integration/idempotence.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.idempotence.sh.lines.txt (captures pre/post config-hash and gNMI Set-related events and asserts equality)
  - Independent pre/post snapshots produced from a run window:
    - Config hashes (before/after, byte-equivalent):
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/idempotence.config-hashes.before.txt
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/idempotence.config-hashes.after.txt
    - gNMI Set-related event stream (before/after, unchanged):
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/idempotence.gnmi-events.before.txt
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/idempotence.gnmi-events.after.txt

- [x] T049 [US2] Add partial target failure/recovery, provider restart mid-transaction, and invalid-YANG tests; include partial SRv6 endpoint programming and prohibit false aggregate Ready or partial service activation
  - File: tests/integration/failure_recovery_invalid_yang.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.failure_recovery_invalid_yang.sh.lines.txt ("partial target failure/recovery" via containerlab stop/start; provider rollout restart mid-transaction; apply invalid YANG and assert failure; partial SRv6 endpoint programming; prohibit false aggregate Ready)

- [x] T050 [US2] Add managed-path drift restoration and unmanaged-path preservation tests
  - File: tests/integration/drift_preservation.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.drift_preservation.sh.lines.txt (managed BGP AS restored; unmanaged interface description preserved)

- [x] T051 [US2] Add update and delete tests proving shared fabric state and unrelated claims survive EVPN and SRv6 service lifecycle changes; verify SRv6-owned claims and SDC Configs are released without removing shared IPv6 underlay state (effect-witness)
  - File: tests/integration/update_delete_survivability.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.update_delete_survivability.sh.lines.txt (writes independent witness files for update and delete)
  - Independent effect-witness artifacts from an actual run:
    - Update preserves the default fabric Network and allows observing the post-update SDC Config set:
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.default-fabric.txt (contains "network.network.kubenet.dev/default-fabric")
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.sdc-configs.after.txt (sorted list of SDC Config objects)
    - Delete reduces SRv6-owned SDC Config count while preserving shared underlay:
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.count.before.txt
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.count.after.txt

Checkpoint assertion: The default fabric plus L2, L3, IRB, and bidirectional SRv6 services converge and pass control-plane, packet-capture, primary/alternate path, lifecycle, failure, drift, ownership, and idempotence acceptance with the evidence above.
