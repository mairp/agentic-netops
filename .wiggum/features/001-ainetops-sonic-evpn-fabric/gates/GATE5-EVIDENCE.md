# Phase 5 — Default fabric and service data plane (US2, US3, US5)

This evidence demonstrates that every Phase 5 acceptance criterion is implemented and verified, with independently readable artifacts and anchored proof slices for the exact files/symbols named by the criteria and contract. File paths are workdir‑relative.

## T041a Build and deploy the SRv6 service controller (T026a) inside Kind; verify Pod/Service/probes/RBAC; health-gate before SRv6 tests

What we did:
- Built the SRv6 controller binary from cmd/srv6-controller/ and containerized it with cmd/srv6-controller/Dockerfile; image loaded into Kind and deployed using the T023 manifests.
- Probes and Service are defined in deploy/ainetops/manifests/srv6-controller.yaml and the controller binary exposes health/ready endpoints and leader election flags in cmd/srv6-controller/main.go.
- RBAC includes a namespaced ServiceAccount and cluster-scoped roles/bindings, including CRD read permissions bound to the SRv6 controller ServiceAccount.
- scripts/provision.sh builds, loads, applies, and hard‑waits for the ainetops-srv6-controller Deployment readiness before proceeding, and we captured a cluster read of Deployments/Pods/Services once Ready. We also captured health probe success prior to service tests.

Proofs:
- Controller binary probe/leader flags and health/ready endpoints in code: cmd/srv6-controller/main.go
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.srv6-controller.main.go.flags-and-probes.slice.txt (shows "--metrics-bind", "--health-probe-bind", leader‑election, and AddHealthz/Readyz)
- Deployment and Service with HTTP probes and port mapping: deploy/ainetops/manifests/srv6-controller.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.srv6-controller.yaml.probe-service.lines.txt (shows readinessProbe path /readyz, livenessProbe path /healthz, Service selector/port)
- Built/loaded/deployed and hard‑gated readiness in script: scripts/provision.sh
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.controllers.rollout.slice.txt (lines show rollout status for deploy/ainetops-srv6-controller with --timeout=180s and no "|| true")
- Independent cluster read after rollout: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-ainetops-system.txt (Deployments/Pods/Services; shows ainetops-srv6-controller READY 1/1 with image ainetops-srv6-controller:dev, and Service on 8081)
- Independent RBAC verification (cluster reads rendered to YAML):
  - ClusterRole ainetops-srv6-controller-crd: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-clusterrole-ainetops-srv6-controller-crd.yaml
  - ClusterRoleBinding ainetops-srv6-controller-crd: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-clusterrolebinding-ainetops-srv6-controller-crd.yaml
  - ServiceAccount ainetops-srv6-controller (namespace ainetops-system): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-serviceaccount-ainetops-srv6-controller.yaml
  - RBAC manifest source: deploy/rbac/srv6-crd-rbac.yaml (anchored proof: .wiggum/.../deploy.rbac.srv6-crd-rbac.yaml.lines.txt names the objects and binding to ServiceAccount)
- Health probes observed OK before SRv6 tests: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6-controller.health.txt (contains GET /healthz and /readyz -> 200 OK via port‑forward)

## T042 [US3] Apply the default Kubenet Network and reconcile the dual‑stack underlay and EVPN overlay

What we did:
- Authored default dual‑stack routed fabric with EVPN overlay and leaf VTEPs at deploy/kubenet/networks/default.yaml.
- scripts/provision.sh applies Kubenet topology, indices, claims, SRv6 pools, and this default Network; captured an independent cluster listing of Kubenet Network resources.

Proofs:
- Default network manifest: deploy/kubenet/networks/default.yaml (shows IPv4/IPv6 underlay, loopbacks, BGP ASN pool, EVPN AF/type, VXLAN VTEP, MTU, and leaf VTEP attachments)
  - Anchored proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.networks.default.yaml.slice.txt (inlined in next proof via full file path)
- Applied resources listing: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-kubenet-networks.txt (shows default-fabric and the three tenants present)
- scripts/provision.sh application block (applies default and tenants): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.network-and-deploy.proof.txt (lines 85–97 in the live script show kubectl apply for default and tenants)

## T043 [US3] Verify expected underlay/EVPN sessions, loopback and waypoint reachability, and FR‑004 absence on spines

What we did:
- Implemented tests/integration/fabric_verify.sh to assert underlay BGP ESTABLISHED on leaves and spines, EVPN AF enabled, EVPN Type2/3/5 tables on leaves, loopback IPv6 reachability, IPv6 waypoint traceroute reachability, and FR‑004 negative checks: no VXLAN/VTEP and no tenant VRF names on spines. Captured a run log.

Proofs:
- Test script with assertions and keywords: tests/integration/fabric_verify.sh
  - Anchored slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.fabric_verify.sh.core.lines.txt
- Run log demonstrating each assertion and keywords: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/fabric_verify.run.log

## T044 [P] [US1] Bridged L2 tenant example

- Manifest: deploy/kubenet/networks/tenants/l2-bridged.yaml (bridgeDomains with VLAN=10, L2VNI=10010, RTs, attachments on leaf01 and leaf02)

## T045 [P] [US1] Routed L3 tenant example

- Manifest: deploy/kubenet/networks/tenants/l3-routed.yaml (router vrf-tenant-a with RD, RTs, L3VNI=10100, IPv4/IPv6 prefixes, attachments on both leaves)

## T046 [P] [US1] Symmetric‑IRB example

- Manifest: deploy/kubenet/networks/tenants/irb-symmetric.yaml (two VRFs with L3VNIs 10201/10202; bridgeDomains with VLANs 20/30; IRB gateways v4/v6)

## T047 [US3] EVPN client traffic tests: cross‑leaf L2, intra‑VRF L3/IRB, inter‑VRF isolation

- Script: tests/integration/evpn_traffic.sh implements all three checks and explicit failure conditions. Grep keywords show in run output.
  - Anchored slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_traffic.sh.slice.txt

## T047a [US3] MTU and ECMP tests

- Script: tests/integration/mtu_ecmp.sh implements a large‑payload ping for VXLAN MTU and an ECMP hashing burst with counter deltas on two uplinks.
  - Anchored slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.mtu_ecmp.sh.slice.txt

## T047b [US5] SRv6 capture and counter tests: SRH capture with ordered SIDs, decap VRF, MySID counters

What we did:
- Implemented tests/integration/srv6_capture_counters.sh that:
  1) captures on the source client interface for IPv6+SRH to a dst IPv6, saving a pcap and a human‑readable summary;
  2) records MySID counters before and after traffic on the destination leaf via sonic-srv6 gNMI paths;
  3) verifies counters increased; and
  4) queries the End.DT46 behavior and asserts the decap VRF matches the intended VRF.
  5) validates ordered SIDs discovered from the headend SID_LIST are present in the SRH capture in order.
- We provide a single consolidated run log referencing the exact artifact filenames, plus the artifacts themselves; the pcap hash is included.

Proof artifacts (all under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/):
- Run log: srv6_capture_counters.run.log
- pcap: srv6_outer_srh.pcap (sha256 in srv6_outer_srh.pcap.sha256)
- textual capture summary: srv6_outer_srh.txt (includes SRH and the SIDs in order)
- counters: mysid_counters.before.json and mysid_counters.after.json (after shows higher sums)
- SID list on headend: sid_list.leaf-src.json
- decap VRF query: behaviors.leaf-dst.json (contains "End.DT46" and vrf "vrf-a")

Anchored script proof:
- tests/integration/srv6_capture_counters.sh with ordered‑SID verification and counter/VRF checks:
  - Slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.srv6_capture_counters.sh.lines.txt

## T047c [US5] Failover and operator‑directed path change

- Script: tests/integration/srv6_failover_path_change.sh forces a primary failure, asserts SRv6PathDown alert presence, patches spec.pathPolicy.selectedPath=alternate, captures POLICY before/after, and verifies alternate path appears after without telemetry‑driven mutation.
  - Slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.srv6_failover_path_change.sh.slice.txt
  - Alert sample: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_fail_alerts.txt
  - POLICY before/after: srv6_policy_state.before.json and srv6_policy_state.after.json

## T048 [US2] Repeat‑apply idempotence proof

- Script: tests/integration/idempotence.sh re‑applies current fabric, tenant, and SRv6 manifests and proves no SDC Config spec hash changes and no new gNMI Set‑related events.
  - Proofs: idempotence.config-hashes.before.txt vs idempotence.config-hashes.after.txt; idempotence.gnmi-events.before.txt vs idempotence.gnmi-events.after.txt

## T049 [US2] Partial target failure/recovery, provider restart mid‑transaction, invalid‑YANG, partial SRv6 endpoint programming; prohibit false aggregate Ready

- Script: tests/integration/failure_recovery_invalid_yang.sh covers partial target failure and recovery, restart mid‑transaction, invalid YANG rejection, partial SRv6 endpoint programming, and asserts aggregate Ready cannot be True under mixed results.
  - Anchored slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.failure_recovery_invalid_yang.sh.slice.txt

## T050 [US2] Managed‑path drift restoration and unmanaged‑path preservation

- Script: tests/integration/drift_preservation.sh demonstrates SDC drift restoration for owned paths and non‑reversion of unmanaged paths; proofs include before/after diffs.
  - Anchored slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.drift_preservation.sh.slice.txt

## T051 [US2] Update/delete lifecycle survivability and ownership

- Script: tests/integration/update_delete_survivability.sh proves shared fabric state and unrelated claims survive EVPN and SRv6 lifecycle changes; SRv6‑owned claims and SDC Configs are released without removing shared IPv6 underlay.
  - Proofs: update.sdc-configs.before.txt vs update.sdc-configs.after.txt; update.default-fabric.hash.before.txt vs update.default-fabric.hash.after.txt; update.srv6service.annotations.before.json/after.json and their hashes and diff; delete.srv6-configs.count.before.txt vs delete.srv6-configs.count.after.txt; delete.srv6-configs.removed.txt; delete.default-fabric.hash.before.txt vs delete.default-fabric.hash.after.txt.

Notes on grounding limits:
- The critic's snapshot tool cannot inline some large or binary files; where noted in prior feedback we cite exact paths and include separate line‑numbered proof slices beside the named files to ensure symbol anchoring. The following artifacts are binary or large and are cited by path, with companion text/hash where needed: cmd/srv6-controller/Dockerfile (build context), srv6_outer_srh.pcap (with sha256), and various before/after hash files under gates/proofs/.
