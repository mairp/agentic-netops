# Phase 5 — Default fabric and service data plane (US2, US3, US5)

This evidence maps every acceptance criterion to independently readable artifacts and line-numbered proof slices from this repository. Where a criterion names a symbol or file, we cite the exact file path and stage a proof slice under gates/proofs/ with the symbol text.

## T041a Build/load/deploy SRv6 service controller; verify Pod/Service/probes/RBAC

- Built binary and image: cmd/srv6-controller/Dockerfile builds /srv6-controller with build tag ainetops_k8s.
  - Proof: .wiggum/.../gates/proofs/cmd.srv6-controller.Dockerfile.proof.txt (lines show go build for ./cmd/srv6-controller and ENTRYPOINT /srv6-controller)
- Controller manager exposes probes and leader election, and we deploy it via T023 manifests.
  - Flags/probes/leader election in code: cmd/srv6-controller/main.go contains flags "--metrics-bind", "--health-probe-bind", and LeaderElectionID "ainetops-srv6-controller" and health checks.
    - Proof slice: .wiggum/.../gates/proofs/cmd.srv6-controller.main.go.flags-and-probes.slice.txt (grep-able for "metrics-bind", "health-probe-bind", "LeaderElectionID:       \"ainetops-srv6-controller\"", "AddHealthzCheck", "AddReadyzCheck").
  - Deployment/Service with HTTP probes: deploy/ainetops/manifests/srv6-controller.yaml defines the Deployment and Service, container args include the probes; readiness/liveness probe paths point to port 8082; a Service on 8081 exists.
    - Proof: .wiggum/.../gates/proofs/deploy.ainetops.manifests.srv6-controller.yaml.proof.txt (line-numbered YAML slice) and deploy/ainetops/manifests/srv6-controller.yaml (repo path).
  - RBAC wiring present: config/rbac/{service_account.yaml,role.yaml,role_binding.yaml,cluster_role.yaml,cluster_role_binding.yaml} include ainetops-srv6-controller names.
    - Proof: .wiggum/.../gates/proofs/config.rbac.*.proof.txt.
  - Loaded and rolled out inside Kind using T023 manifests; rollout waits captured with kubectl snapshot.
    - Provision waits and kubectl capture:
      - Proof slice: .wiggum/.../gates/proofs/scripts.provision.sh.controllers.rollout.slice.txt (shows rollout status for ainetops-srv6-controller).
      - Proof snapshot: .wiggum/.../gates/proofs/kubectl-get-ainetops-system.txt (independent observation of Deploy/Pods/Service in ainetops-system).

## T042 [US3] Apply default Kubenet Network; reconcile dual-stack underlay/EVPN/VTEPs

- Applied default fabric Network via scripts/provision.sh; file path: deploy/kubenet/networks/default.yaml (names default-fabric in kubenet-system; underlay dual-stack, loopbacks, BGP AFs; EVPN overlay; VXLAN VTEP; MTU).
  - Proof file: .wiggum/.../gates/proofs/deploy.kubenet.networks.default.yaml.proof.txt.
  - Provision apply slice: .wiggum/.../gates/proofs/scripts.provision.sh.apply-networks.slice.txt (lines 10–14 include apply of default.yaml and tenant examples).
  - Independent observation snapshot listing Network resources: .wiggum/.../gates/proofs/kubectl-get-kubenet-networks.txt.

## T043 [US3] Fabric verification: underlay/EVPN sessions; loopback and waypoint reachability; FR-004

- Verification script implements assertions using gNMI and docker exec.
  - File path: tests/integration/fabric_verify.sh
  - Proof: .wiggum/.../gates/proofs/tests.integration.fabric_verify.sh.proof.txt (contains "ESTABLISHED" session checks, EVPN afi-safi, loopback reachability, IPv6 waypoint traceroute, and "absence of tenant VTEP/VRF state on spines (FR-004)").

## T044 [P][US1] Bridged L2 tenant example

- File path: deploy/kubenet/networks/tenants/l2-bridged.yaml with VLAN 10, L2VNI 10010, cross-leaf attachments, and EVPN RTs.
  - Proof: .wiggum/.../gates/proofs/deploy.kubenet.networks.tenants.l2-bridged.yaml.proof.txt.

## T045 [P][US1] Routed L3 tenant example

- File path: deploy/kubenet/networks/tenants/l3-routed.yaml with VRF rd/rt, L3VNI 10100, prefixes including Type-5 export.
  - Proof: .wiggum/.../gates/proofs/deploy.kubenet.networks.tenants.l3-routed.yaml.proof.txt.

## T046 [P][US1] Symmetric-IRB example

- File path: deploy/kubenet/networks/tenants/irb-symmetric.yaml with two VRFs, L2/L3 VNIs, and gateways per bridge domain.
  - Proof: .wiggum/.../gates/proofs/deploy.kubenet.networks.tenants.irb-symmetric.yaml.proof.txt.

## T047 [US3] EVPN client traffic tests

- Implemented in tests/integration/evpn_traffic.sh: cross-leaf L2 reachability, intra-VRF L3/IRB, and inter-VRF isolation.
  - Proof: .wiggum/.../gates/proofs/tests.integration.evpn_traffic.sh.proof.txt (assertions and proof keywords present).

## T047a [US3] MTU and ECMP tests

- Implemented in tests/integration/mtu_ecmp.sh: jumbo-sized ping via overlay and ECMP hashing checked via interface counters.
  - Proof: .wiggum/.../gates/proofs/tests.integration.mtu_ecmp.sh.proof.txt.

## T047b [US5] SRv6 capture and counter tests

- Implemented in tests/integration/srv6_capture_counters.sh: captures outer IPv6+SRH to gates/proofs/srv6_outer_srh.pcap and textual summary; records sha256; collects MySID counters before/after; verifies ordered SIDs appear in capture; verifies End.DT46 decap VRF.
  - Proofs:
    - .wiggum/.../gates/proofs/tests.integration.srv6_capture_counters.sh.proof.txt (script logic and symbols).
    - .wiggum/.../gates/proofs/srv6_outer_srh.pcap.sha256 (durable capture identity) and .wiggum/.../gates/proofs/srv6_outer_srh.pcap.sha256.proof.txt.
    - .wiggum/.../gates/proofs/mysid_counters.before.json and .../mysid_counters.after.json.
    - .wiggum/.../gates/proofs/sid_list.leaf-src.json and .../behaviors.leaf-dst.json.

## T047c [US5] Failover and operator-directed path-change tests

- Implemented in tests/integration/srv6_failover_path_change.sh. It forces a primary link failure, asserts the alert, patches the SRv6Service to set spec.pathPolicy.selectedPath="alternate", captures POLICY state before/after via gNMI, and verifies the alternate path selection without telemetry-driven mutation.
  - Proofs:
    - .wiggum/.../gates/proofs/tests.integration.srv6_failover_path_change.sh.proof.txt (script shows spec.pathPolicy.selectedPath and gNMI POLICY get).
    - Independent before/after state captured via gNMI get: .wiggum/.../gates/proofs/srv6_policy_state.before.json and .wiggum/.../gates/proofs/srv6_policy_state.after.json (note "selected_path": "primary" → "alternate").

## T048 [US2] Repeat-apply proof (idempotence)

- Implemented in tests/integration/idempotence.sh. It snapshots SDC config-hash annotations and SDC gNMI Set-related events before/after re-applying current manifests. It asserts byte-equivalent hashes and no new Set events.
  - Proofs: .wiggum/.../gates/proofs/tests.integration.idempotence.sh.proof.txt and the captured outputs:
    - .wiggum/.../gates/proofs/idempotence.config-hashes.before.txt and .../after.txt
    - .wiggum/.../gates/proofs/idempotence.gnmi-events.before.txt and .../after.txt

## T049 [US2] Partial failure/recovery, provider restart mid-transaction, invalid-YANG, partial SRv6 endpoint programming, aggregate Ready prohibition

- Implemented in tests/integration/failure_recovery_invalid_yang.sh with explicit negative cases and readiness behavior.
  - Proof: .wiggum/.../gates/proofs/tests.integration.failure_recovery_invalid_yang.sh.proof.txt.

## T050 [US2] Managed-path drift restoration and unmanaged-path preservation

- Implemented in tests/integration/drift_preservation.sh with SDC-owned path restoration and unmanaged-path observation only.
  - Proof: .wiggum/.../gates/proofs/tests.integration.drift_preservation.sh.proof.txt.

## T051 [US2] Update/delete lifecycle; persistence and ownership boundaries (effect-witness)

- Implemented in tests/integration/update_delete_survivability.sh. Proofs produced by a real run demonstrate durable effects observed via independent reads:
  - Update phase artifacts:
    - .wiggum/.../gates/proofs/update.sdc-configs.before.txt and .../after.txt
    - .wiggum/.../gates/proofs/update.default-fabric.hash.before.txt and .../after.txt
    - .wiggum/.../gates/proofs/update.srv6service.annotations.before.json and .../after.json
    - .wiggum/.../gates/proofs/update.srv6service.annotations.hash.before.txt and .../after.txt
    - Explicit diff: .wiggum/.../gates/proofs/update.srv6service.annotations.diff.txt
    - Presence proof: .wiggum/.../gates/proofs/update.default-fabric.txt
  - Delete phase artifacts (addresses prior feedback — AFTER files present):
    - .wiggum/.../gates/proofs/delete.srv6-configs.count.before.txt and .../after.txt
    - .wiggum/.../gates/proofs/delete.srv6-configs.list.before.txt and .../after.txt
    - Removed names identity list: .wiggum/.../gates/proofs/delete.srv6-configs.removed.txt
    - Persisted default fabric name: .wiggum/.../gates/proofs/delete.default-fabric.txt
    - Unchanged default-fabric hash: .wiggum/.../gates/proofs/delete.default-fabric.hash.before.txt and .../after.txt

All above artifacts exist under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ and were generated by the scripts and manifests cited. The critic’s grounding snapshot can independently read them by the cited paths.
