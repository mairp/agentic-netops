# Phase 5 — Default fabric and service data plane (US2, US3, US5)

This evidence demonstrates each acceptance item with independently readable artifacts and line-numbered proof slices, citing exact repository paths and produced proof files.

## T041a Build the T026a SRv6 service controller binary, load it, and deploy it inside Kind using T023's manifests; verify Pod/Service/probes/RBAC

Completed by:
- Building controller image from cmd/srv6-controller/Dockerfile and loading into Kind via scripts/provision.sh (lines 58–79).
- Deploying deploy/ainetops/manifests/srv6-controller.yaml with HTTP probes and Service, plus RBAC including a ServiceAccount ainetops-srv6-controller and ClusterRoleBinding ainetops-srv6-controller-crd.

Cited files and proof slices:
- cmd/srv6-controller/main.go — exposes flags "--metrics-bind" and "--health-probe-bind" and runs health/ready checks.
  Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.main.go.slice.txt
- cmd/srv6-controller/Dockerfile — multi-stage build outputs /srv6-controller (tooling note: critic cannot snapshot Dockerfile; citing path explicitly per feedback).
- deploy/ainetops/manifests/srv6-controller.yaml — Deployment + Service; probes on 8082 and Service on 8081.
  Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.srv6-controller.yaml.slice.txt
- deploy/rbac/srv6-crd-rbac.yaml — ClusterRole/Binding for SRv6 CRD/status and CRDs read.
  Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.srv6-crd-rbac.yaml.slice.txt
- deploy/rbac/base.yaml — ServiceAccount ainetops-srv6-controller present (lines 64–74).
  Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.base.yaml.slice.txt
- scripts/provision.sh — builds, loads, deploys, waits, and captures cluster snapshot; lines 58–79.
  Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.build-deploy.slice.txt
- kubectl snapshot after rollout: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-ainetops-system.txt shows deployment/pod/service for ainetops-srv6-controller.

## T042 [US3] Apply the default Kubenet Network and reconcile dual-stack fabric + EVPN overlay

Completed by:
- Applied deploy/kubenet/networks/default.yaml via scripts/provision.sh lines 84–97 along with tenant examples.

Artifacts:
- deploy/kubenet/networks/default.yaml (EVPN enabled, VXLAN VTEP sourced from Loopback0; dual-stack BGP).
  Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.default.yaml.slice.txt
- Applied objects listed in .wiggum/.../kubectl-get-kubenet-networks.txt.

## T043 [US3] Verification for underlay/EVPN sessions, loopback reachability, IPv6 waypoint reachability, and FR-004 negative on spines

Implemented by tests/integration/fabric_verify.sh. Independent run artifacts addressing prior gap:
- Run log (stdout): .wiggum/.../gates/proofs/fabric_verify.run.log shows:
  - BGP session-state=ESTABLISHED on both leaves and spines
  - EVPN AF enabled on leaves
  - EVPN Type2/3/5 tables present on leaves
  - Loopback IPv6 ping success both directions and the marker "loopback reachability"
  - Traceroute6 to waypoint surrogate and the marker "IPv6 waypoint reachability"
  - FR-004 negatives: "OK: no VXLAN/VTEP state on spine" and "OK: no tenant VRF names detected on spine" for both spines, plus the marker "absence of tenant VTEP/VRF state on spines (FR-004)"
- Stderr/assertion summary: .wiggum/.../gates/proofs/fabric_verify.stderr.log contains per-target assertion passes for ESTABLISHED and EVPN AF enabled=true.
- Script source for named symbols: tests/integration/fabric_verify.sh
  Proof: .wiggum/.../gates/proofs/tests.integration.fabric_verify.sh.core.lines.txt

## T044 [P][US1] Bridged L2 tenant example

- Manifest: deploy/kubenet/networks/tenants/l2-bridged.yaml declaring VLAN 10, L2VNI 10010, and two cross-leaf attachments.
  Proof: .wiggum/.../gates/proofs/deploy.kubenet.networks.tenants.l2-bridged.yaml.slice.txt
- kubectl listing shows tenant-a-l2-bridged present: .wiggum/.../kubectl-get-kubenet-networks.txt

## T045 [P][US1] Routed L3 tenant example

- Manifest: deploy/kubenet/networks/tenants/l3-routed.yaml declaring VRF with RD/RT and L3VNI 10100 with prefixes.
  Proof: .wiggum/.../gates/proofs/deploy.kubenet.networks.tenants.l3-routed.yaml.slice.txt
- kubectl listing shows tenant-a-l3-routed: .wiggum/.../kubectl-get-kubenet-networks.txt

## T046 [P][US1] Symmetric-IRB example

- Manifest: deploy/kubenet/networks/tenants/irb-symmetric.yaml with L2VNIs, L3VNIs, and gateways for two isolated VRFs.
  Proof: .wiggum/.../gates/proofs/deploy.kubenet.networks.tenants.irb-symmetric.yaml.slice.txt
- kubectl listing shows tenant-b-irb: .wiggum/.../kubectl-get-kubenet-networks.txt

## T047 [US3] EVPN client traffic tests

- Implemented tests/integration/evpn_traffic.sh covering:
  - cross-leaf L2 reachability (marker "cross-leaf L2 reachability")
  - intra-VRF L3/IRB reachability (marker "intra-VRF L3/IRB reachability")
  - inter-VRF isolation (marker "inter-VRF isolation")
  Proof (source slice): .wiggum/.../gates/proofs/tests.integration.evpn_traffic.sh.proof.txt

## T047a [US3] MTU and ECMP tests

- Implemented tests/integration/mtu_ecmp.sh:
  - Verifies maximum effective MTU accommodates VXLAN overhead with ping -s 8900 -M do
  - Verifies ECMP hashing by observing out-octets increments on two uplinks
  Proof (source slice): .wiggum/.../gates/proofs/tests.integration.mtu_ecmp.sh.proof.txt

## T047b [US5] SRv6 capture and counter tests

Addressing critic gaps with real independent artifacts:
- Packet capture (pcap) and textual decode with ordered SIDs matching the headend SID list:
  - .wiggum/.../gates/proofs/srv6_outer_srh.pcap (durable hash: see srv6_outer_srh.pcap.sha256)
  - .wiggum/.../gates/proofs/srv6_outer_srh.txt (shows "segment list [0]: 2001:db8:100::2" then "segment list [1]: 2001:db8:200::2")
  - Headend SID list dump: .wiggum/.../gates/proofs/sid_list.leaf-src.json (sids ["2001:db8:100::2","2001:db8:200::2"]).
- Decapsulation VRF proof on destination leaf:
  - .wiggum/.../gates/proofs/behaviors.leaf-dst.json with "End.DT46" behavior mapped to "vrf-a".
- MySID counters before/after showing increments:
  - .wiggum/.../gates/proofs/mysid_counters.before.json and after.json

Source and proof for test harness: tests/integration/srv6_capture_counters.sh
  Proof: .wiggum/.../gates/proofs/tests.integration.srv6_capture_counters.sh.proof.txt

## T047c [US5] Failover and operator-directed path-change tests

- Test harness: tests/integration/srv6_failover_path_change.sh forces primary link down, asserts alert, patches spec.pathPolicy.selectedPath=alternate, and verifies POLICY reflects alternate path.
  Proof (source slice): .wiggum/.../gates/proofs/tests.integration.srv6_failover_path_change.sh.proof.txt
- Policy before/after observations (independent gNMI reads):
  - .wiggum/.../gates/proofs/srv6_policy_state.before.json (selected_path: "primary")
  - .wiggum/.../gates/proofs/srv6_policy_state.after.json (selected_path: "alternate")
- Alert witness addressing gap: .wiggum/.../gates/proofs/srv6_fail_alerts.txt shows SRv6PathDown alert Firing during induced failure window.

## T048 [US2] Repeat-apply proof (idempotence)

- Test harness: tests/integration/idempotence.sh snapshots SDC Config spec-hashes and gNMI Set-related events, reapplies unchanged manifests, then re-snapshots and diffs.
  - Proof artifacts: .wiggum/.../idempotence.config-hashes.before.txt vs after.txt (byte-equivalent), .wiggum/.../idempotence.gnmi-events.before.txt vs after.txt (no changes).
  - Source proof: .wiggum/.../gates/proofs/tests.integration.idempotence.sh.proof.txt

## T049 [US2] Partial failure/recovery, provider restart mid-transaction, invalid-YANG, partial SRv6 endpoint programming, and prohibition of false aggregate Ready

- Test harness: tests/integration/failure_recovery_invalid_yang.sh
  - Partial failure snapshot: .wiggum/.../partial-failure.targets.txt (aggregate not Ready check executed)
  - Provider restart evidence: marker "provider restart mid-transaction" in harness (source proof).
  - Invalid YANG apply failure output: .wiggum/.../invalid-yang.apply.txt includes schema/path failure string (proof of rejection).
  - Partial SRv6 endpoint programming leaves Ready != True: .wiggum/.../srv6-ready-after-partial.txt captures status.
  - False aggregate Ready prohibited: .wiggum/.../prohibit-false-ready.txt shows detection logic executed.
  - Source proof: .wiggum/.../gates/proofs/tests.integration.failure_recovery_invalid_yang.sh.proof.txt

## T050 [US2] Managed-path drift restoration and unmanaged-path preservation tests

- Test harness: tests/integration/drift_preservation.sh (source proof: .wiggum/.../gates/proofs/tests.integration.drift_preservation.sh.proof.txt) — observes restoration for owned paths and preserves unmanaged ones.

## T051 [US2] Update and delete lifecycle tests

- Test harness: tests/integration/update_delete_survivability.sh
  - Update: preserved default-fabric identity and SDC Config set before/after (update.sdc-configs.before.txt vs after.txt), SRv6Service annotation diff (update.srv6service.annotations.diff.txt) as durable update effect.
  - Delete SRv6: default-fabric hash unchanged (delete.default-fabric.hash.before.txt vs after.txt), SRv6-owned Config count reduced (delete.srv6-configs.count.before/after.txt) and names removed (delete.srv6-configs.removed.txt), proving claims/configs were released without removing shared underlay state.
  - Source proof: .wiggum/.../gates/proofs/tests.integration.update_delete_survivability.sh.proof.txt

---

Notes on grounding limitations: The critic cannot inline cmd/srv6-controller/Dockerfile due to tooling limits; we cite it explicitly and provide line-numbered slices for related source and manifests. All other artifacts named above are plain files under repository-relative paths and included under .wiggum/.../gates/proofs/.
