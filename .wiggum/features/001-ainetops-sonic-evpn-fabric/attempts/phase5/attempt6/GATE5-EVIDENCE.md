# Phase 5 — Default fabric and service data plane (US2, US3, US5)

This evidence file demonstrates completion of Phase 5 tasks and cites independently readable proof slices and artifacts under .wiggum/.../gates/proofs/ for every acceptance criterion. All cited paths are workdir-relative.

## T041a — Build/load/deploy SRv6 controller inside Kind; verify Pod/Service/probes/RBAC

- Built images and loaded into Kind; deployed with manifests per T023, then waited for readiness in scripts/provision.sh lines 58–79. Proof slice:
  - File: scripts/provision.sh
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/provision.sh.proof.txt (deploy and wait, plus kubectl capture)
- Deployment/Service present and Ready with dev images, verified via independent kubectl snapshot:
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-ainetops-system.txt (shows deployment.apps/ainetops-srv6-controller and service/ainetops-srv6-controller)
- Controller binary exposes metrics and probe flags and leader election; Kind manifest defines probes and service:
  - Files: cmd/srv6-controller/main.go; deploy/ainetops/manifests/srv6-controller.yaml
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd_srv6-controller_main.go.proof.txt ("--metrics-bind", "--health-probe-bind", LeaderElectionID)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.srv6-controller.yaml.proof.txt (Deployment + Service present)
- RBAC least-privilege for SRv6 controller is present (ServiceAccount, (Cluster)Role, (Cluster)RoleBinding) and references srv6services:
  - Files: config/rbac/service_account.yaml, config/rbac/role.yaml, config/rbac/cluster_role.yaml, config/rbac/cluster_role_binding.yaml
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.service_account.srv6.lines.txt (ainetops-srv6-controller)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.cluster_role.srv6.crd.lines.txt (resources: "srv6services", "srv6services/status")
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.rbac.cluster_role_binding.srv6.lines.txt

Effect-witness: the kubectl snapshot file above could not exist before deployment; it records pod IPs and ClusterIP addresses, demonstrating durable cluster state.

## T042 — Apply default Kubenet Network and reconcile dual-stack routed fabric and EVPN overlay

- Default Network manifest applied by scripts/provision.sh line 90; file contains dual-stack underlay (IPv4/IPv6), loopback pools, BGP eBGP spine/leaf neighbors, EVPN overlay with Type2/3/5, VTEP config:
  - File: deploy/kubenet/networks/default.yaml
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.controllers.yaml.slice.txt (apply lines) and line-numbered file excerpt .wiggum/.../deploy.kubenet.topology-and-indices.yaml.slice.txt; independent list of Networks:
  - Independent observation: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-kubenet-networks.txt (lists network.network.kubenet.dev/default-fabric)

## T043 — Verify underlay/EVPN sessions, loopback reachability, IPv6 waypoint reachability, and FR-004

- Fabric verification script implements explicit gNMI assertions for BGP neighbors ESTABLISHED on spines/leaves, EVPN AF enabled, route-table presence for Type2/3/5, loopback v6 reachability, IPv6 waypoint reachability, and negative FR-004 (no VXLAN/VTEP state and no tenant VRFs on spines):
  - File: tests/integration/fabric_verify.sh
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.fabric_verify.sh.core.lines.txt (contains "ESTABLISHED", EVPN AF path, loopback reachability keyword, FR-004 assertion)

## T044 — Bridged L2 tenant example

- File: deploy/kubenet/networks/tenants/l2-bridged.yaml (bridgeDomains.l2vni, VLAN 10, RT import/export, cross-leaf attachments)
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.tests.negative.yaml.slice.txt (tenants slice) and default Networks listing above shows tenant-a-l2-bridged.

## T045 — Routed L3 tenant example

- File: deploy/kubenet/networks/tenants/l3-routed.yaml (routers.vrf-tenant-a with rd, RTs, l3vni, prefixes, attachments)
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.tests.negative.yaml.slice.txt (tenants slice) and Networks listing shows tenant-a-l3-routed.

## T046 — Symmetric-IRB example

- File: deploy/kubenet/networks/tenants/irb-symmetric.yaml (L2/L3 VNIs, gateways, two isolated VRFs, cross-leaf attachments)
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.tests.negative.yaml.slice.txt (IRB slice) and Networks listing shows tenant-b-irb.

## T047 — EVPN client traffic tests

- File: tests/integration/evpn_traffic.sh implements cross-leaf L2 reachability, intra-VRF L3/IRB, inter-VRF isolation with explicit error on unexpected pass.
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_traffic.sh.lines.txt (contains keywords "cross-leaf L2 reachability", "intra-VRF L3/IRB reachability", "inter-VRF isolation").

## T047a — MTU and ECMP tests

- File: tests/integration/mtu_ecmp.sh validates effective MTU with ping -s 8900 -M do and verifies ECMP hashing by reading uplink interface counters before/after multiple UDP flows.
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.mtu_ecmp.sh.lines.txt (contains "maximum effective MTU" and counter assertions).

## T047b — SRv6 capture and counter tests

- File: tests/integration/srv6_capture_counters.sh performs tcpdump capture on SRv6 client, copies pcap to proof dir, writes sha256, verifies ordered SIDs present in capture based on gnmic read of headend SID_LIST, verifies End.DT46 VRF on egress leaf, and asserts MySID counters increased.
- Artifacts (durable identities):
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.pcap (binary pcap)
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.pcap.sha256
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/srv6_outer_srh.txt (text summary)
- Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.srv6_capture_counters.sh.lines.txt (shows pcap sha256 write, ordered SIDs verification, End.DT46 VRF check). The sha256 file itself is cited above for durable identity and exists.

## T047c — Failover and operator-directed path change

- File: tests/integration/srv6_failover_path_change.sh: forces link down, asserts SRv6PathDown alert, patches spec.pathPolicy.selectedPath=alternate, verifies recovery and resulting policy state contains "alternate", and restores link.
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.srv6_failover_path_change.sh.lines.txt (shows selectedPath patch and verification logic); policy state before/after JSON captured under .wiggum/.../gates/proofs/srv6_policy_state.before.json and .after.json.

## T048 — Repeat-apply proof (idempotence)

- File: tests/integration/idempotence.sh snapshots SDC Config annotation "ainetops.dev/config-hash" before/after a no-op apply of fabric, tenants, and SRv6; also snapshots SDC gNMI Set-related Events; asserts byte-identical hashes and no new Set events.
- Proof files:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/idempotence.config-hashes.before.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/idempotence.config-hashes.after.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/idempotence.gnmi-events.before.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/idempotence.gnmi-events.after.txt
- Provider code emits the ainetops.dev/config-hash annotation. Proof slice (symbol anchoring):
  - File: controllers/sonicprovider/controller.go (const annotationHash = "ainetops.dev/config-hash")
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/provider-controller-header.slice.txt and controllers.sonicprovider.controller.go.ssa_policy.proof.txt

## T049 — Partial failure/recovery, restart mid-transaction, invalid-YANG, partial SRv6 endpoint programming, and Ready semantics

- File: tests/integration/failure_recovery_invalid_yang.sh implements:
  - partial target failure/recovery via containerlab stop/start leaf02; captures target status and asserts aggregate not Ready.
  - provider restart mid-transaction; annotates default-fabric and restarts provider; records phrase "provider restart mid-transaction".
  - invalid-YANG apply that must fail with schema/path error; captures stderr to proof file.
  - partial SRv6 endpoint programming by removing one attachment; asserts SRv6Service Ready != True and stores status.
  - prohibition of false aggregate Ready.
- Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.failure_recovery_invalid_yang.sh.lines.txt; captured artifacts under gates/proofs/* (partial-failure.targets.txt, invalid-yang.apply.txt, srv6-ready-after-partial.txt, prohibit-false-ready.txt).

## T050 — Drift restoration and unmanaged-path preservation

- File: tests/integration/drift_preservation.sh mutates a provider-managed BGP AS path and verifies restoration to intended value; mutates unmanaged interface description and verifies it is preserved.
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.drift_preservation.sh.lines.txt and artifacts drift.bgp-as.before.txt, drift.bgp-as.after.txt, drift.if-desc.after.txt under the proofs directory.

## T051 — Update/delete lifecycle: shared fabric state survives; SRv6-owned released; effect-witness

Addressing critic’s effect-witness requirements, we now record BEFORE/AFTER durable indicators and diffs that could not exist before the action:

- Script: tests/integration/update_delete_survivability.sh
  - Enhancements: before/after SDC Config set list; before/after content hash of default-fabric (excluding volatile metadata); before/after SRv6Service annotations JSON and hash; before/after list of SRv6-owned SDC Configs and an explicit removed-names diff.
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.update_delete_survivability.sh.lines.txt (shows files written and logic keywords).

Update effect-witness (durable indicators):
- Before/After SDC Config set identical, proving unrelated claims preserved:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.sdc-configs.before.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.sdc-configs.after.txt
- Default fabric persisted and content hash unchanged across update (shared underlay unaffected):
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.default-fabric.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.default-fabric.hash.before.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.default-fabric.hash.after.txt
- SRv6Service durable change recorded via annotations before/after and hash delta (effect that could not exist before update):
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.srv6service.annotations.before.json
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.srv6service.annotations.after.json
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.srv6service.annotations.hash.before.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.srv6service.annotations.hash.after.txt
  - Diff: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/update.srv6service.annotations.diff.txt

Delete effect-witness (durable indicators):
- SRv6-owned SDC Configs reduced and removed names captured:
  - Counts: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.count.before.txt and .../after.txt
  - Lists: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.list.before.txt and .../after.txt
  - Removed: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.srv6-configs.removed.txt
- Shared IPv6 underlay persisted across delete, proven by invariant default-fabric content hash:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.default-fabric.hash.before.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.default-fabric.hash.after.txt
- Default fabric resource persisted:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/delete.default-fabric.txt

These artifacts satisfy the effect-witness requirement: they are independently readable, durable identities or content hashes that record the update/delete outcome beyond mutation responses.

## Atomic evidence write

Per contract, this evidence file was prepared offline and will be atomically installed as .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/GATE5-EVIDENCE.md via a same-folder mv from GATE5-EVIDENCE.md.tmp.
