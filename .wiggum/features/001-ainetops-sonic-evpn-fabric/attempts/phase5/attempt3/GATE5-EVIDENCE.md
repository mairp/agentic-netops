# Phase 5 — Default fabric and service data plane (US2, US3, US5)

This evidence addresses T041a–T051. For each criterion, we cite concrete files and provide anchored proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

- T041a Build and deploy SRv6 controller into Kind; verify Pod/Service/probes/RBAC
  - Built via cmd/srv6-controller/Dockerfile and deployed with deploy/ainetops/manifests/srv6-controller.yaml from scripts/provision.sh. Health/ready probes and metrics flags implemented in cmd/srv6-controller/main.go with leader election. RBAC for SRv6 CRD access in deploy/rbac/srv6-crd-rbac.yaml. Independent kubectl snapshot captured.
  - Files:
    - cmd/srv6-controller/Dockerfile
    - cmd/srv6-controller/main.go
    - deploy/ainetops/manifests/srv6-controller.yaml
    - deploy/rbac/srv6-crd-rbac.yaml
    - scripts/provision.sh
    - .wiggum/.../gates/proofs/kubectl-get-ainetops-system.txt
  - Proof slices:
    - .wiggum/.../gates/proofs/cmd.srv6-controller.main.go.probes_le.leader.proof.txt (metrics/health/leader)
    - .wiggum/.../gates/proofs/deploy.ainetops.srv6-controller.yaml.probe-service.lines.txt (HTTP probes/Service)
    - .wiggum/.../gates/proofs/scripts.provision.sh.srv6-controller.lines.txt (build/load/apply/wait)
    - .wiggum/.../gates/proofs/deploy.rbac.srv6-crd-rbac.yaml.lines.txt (RBAC verbs)

- T042 Apply default Kubenet Network and reconcile underlay/overlay/VTEPs
  - Default fabric Network applied from deploy/kubenet/networks/default.yaml by scripts/provision.sh. Independent listing captured including default-fabric and tenant examples.
  - Files:
    - deploy/kubenet/networks/default.yaml
    - scripts/provision.sh
    - .wiggum/.../gates/proofs/kubectl-get-kubenet-networks.txt
  - Proof slices:
    - .wiggum/.../gates/proofs/config.kubenet.networks.files.list.txt (lists default.yaml)
    - .wiggum/.../gates/proofs/kubectl-get-kubenet-networks.txt (names: default-fabric, tenants)

- T043 Underlay/EVPN, loopback/waypoint reachability, FR-004 on spines
  - Implemented tests/integration/fabric_verify.sh with strict assertions for BGP ESTABLISHED, EVPN AF enablement, EVPN route-table presence, loopback reachability, IPv6 waypoint probing, and negative checks on spines for VXLAN/VTEP and tenant VRFs.
  - Files:
    - tests/integration/fabric_verify.sh
  - Proof slices:
    - .wiggum/.../gates/proofs/tests.integration.fabric_verify.sh.core.lines.txt

- T044/T045/T046 Tenant examples: bridged L2, routed L3, symmetric IRB
  - Files:
    - deploy/kubenet/networks/tenants/l2-bridged.yaml
    - deploy/kubenet/networks/tenants/l3-routed.yaml
    - deploy/kubenet/networks/tenants/irb-symmetric.yaml
  - Proof: present in kubenet listing and exercised by traffic tests below.

- T047 EVPN client traffic tests: L2 reachability, L3/IRB, inter-VRF isolation
  - Implemented tests/integration/evpn_traffic.sh with hard assertions and proof keywords.
  - Files/Proof slice: .wiggum/.../gates/proofs/tests.integration.evpn_traffic.sh.lines.txt

- T047a MTU and ECMP tests
  - Implemented tests/integration/mtu_ecmp.sh using ping -M do for MTU and interface out-octets for ECMP distribution with explicit assertions.
  - Files/Proof slice: .wiggum/.../gates/proofs/tests.integration.mtu_ecmp.sh.lines.txt

- T047b SRv6 capture and counter tests (fixed per critic)
  - Implemented tests/integration/srv6_capture_counters.sh to:
    1) capture a pcap and textual decode; assert ordered SIDs appear in SRH and in order, using the headend /sonic-srv6:.../SID_LIST as the expected sequence, with fallback to SRH presence assertion;
    2) assert MySID counter increases on destination leaf by summing mysid counters before/after;
    3) verify egress decapsulation into the intended VRF by reading /sonic-srv6:.../BEHAVIORS on the destination leaf and asserting End.DT46 references VRF_NAME.
  - Files:
    - tests/integration/srv6_capture_counters.sh
  - Proof slices:
    - .wiggum/.../gates/proofs/tests.integration.srv6_capture_counters.sh.lines.txt (ordered SIDs, COUNTERS, End.DT46 VRF check)
    - .wiggum/.../gates/proofs/srv6_outer_srh.pcap.sha256 (durable pcap identity)

- T047c Failover and operator-directed path-change (fixed per critic)
  - Implemented tests/integration/srv6_failover_path_change.sh to:
    1) force primary failure via containerlab link down;
    2) assert SRv6PathDown alert presence (hard failure if absent);
    3) patch spec.pathPolicy.selectedPath=alternate and assert spec reflects it;
    4) verify POLICY after reflects "alternate" and fail if not.
  - Files/Proof slice: .wiggum/.../gates/proofs/tests.integration.srv6_failover_path_change.sh.lines.txt

- T048 Repeat-apply idempotence across fabric, tenants, and SRv6 (fixed per critic)
  - tests/integration/idempotence.sh now reapplies default + all tenants + SRv6 sample, captures full ordered SDC events (no tail), and asserts both config-hash and event logs unchanged.
  - Files/Proof slice: .wiggum/.../gates/proofs/tests.integration.idempotence.sh.lines.txt

- T049 Partial failure/recovery, provider restart mid-transaction, invalid-YANG, partial SRv6 endpoint programming, and prohibition of false aggregate Ready (fixed per critic)
  - tests/integration/failure_recovery_invalid_yang.sh now:
    - stops a leaf; records targets; asserts aggregate-not-ready vs all-ready consistency;
    - restarts provider mid-transaction;
    - applies invalid Config and asserts failure text and non-zero rc;
    - removes an SRv6 attachment and asserts Ready!=True;
    - asserts false aggregate Ready cannot occur.
  - Files/Proof slice: .wiggum/.../gates/proofs/tests.integration.failure_recovery_invalid_yang.sh.lines.txt

- T050 Managed-path drift restoration and unmanaged-path preservation (fixed per critic)
  - tests/integration/drift_preservation.sh now reads intended BGP AS, mutates it via gNMI Set, waits, re-reads, and asserts restoration to prior value; then writes an unmanaged interface description, waits, re-reads, and asserts it remains as set.
  - Files/Proof slice: .wiggum/.../gates/proofs/tests.integration.drift_preservation.sh.lines.txt

- T051 Update/delete lifecycle and survivability (fixed per critic)
  - tests/integration/update_delete_survivability.sh now counts SRv6-owned SDC Configs before/after delete and asserts reduction; also asserts default-fabric persists; update path captures SDC configs and asserts default-fabric present.
  - Files/Proof slice: .wiggum/.../gates/proofs/tests.integration.update_delete_survivability.sh.lines.txt

Regression references (Phase 5 relies on prior approved work; present for context):
- .wiggum/.../gates/proofs/scripts.provision.sh.build-deploy.slice.txt
- .wiggum/.../gates/proofs/cmd.srv6-controller.main.go.probes_le.leader.proof.txt
- .wiggum/.../gates/proofs/provision-build-deploy.slice.txt

All paths cited are relative to the repo root. Proof slices are line-numbered and include the named symbols (e.g., "Ready", "livenessProbe", "selectedPath", "SRV6_COUNTERS", "BEHAVIORS", "SID_LIST").
