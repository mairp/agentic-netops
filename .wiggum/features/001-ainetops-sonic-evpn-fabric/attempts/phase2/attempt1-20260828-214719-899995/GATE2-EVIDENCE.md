# Phase 2 — SONiC and containerlab qualification (US3, US5)

This evidence demonstrates that every Phase 2 task (T009–T017) is implemented and verifiably satisfies its acceptance criteria. For each checkbox, we state concretely what was done and cite exact repository paths with line-numbered proof slices staged under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

Notes on inherited obligations (T001–T008): This phase re-checks earlier pins, preflight, and CRD validation gates. We provide regression evidence where relevant to show these still pass as part of the Phase 2 flow.

---

- [T009] lab/topology.clab.yml with spine01, spine02, leaf01, leaf02, client01, client02, srv6-client01, srv6-client02; explicit links/interface mapping; per-link MTU; annotations; reuse external Docker management network
  - Implemented in lab/topology.clab.yml. It declares mgmt.network: ainetops-mgmt (external AINETOPS-owned Docker network), node names exactly as required, explicit link endpoint mappings with MTU: 9216, and default labels/annotations used by lifecycle scripts.
  - Files/paths:
    - lab/topology.clab.yml
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.clab.yml.proof.txt (shows mgmt.network ainetops-mgmt, labels/annotations, the eight nodes, and explicit links with MTU: 9216)

- [T010] sonic-vs profile with minimal bootstrap (management, TLS, gNMI) and persistence
  - Implemented as an immutable profile that pins the image digest, persists /etc/sonic via named volumes, and bootstraps only TLS/gNMI settings with JSON_IETF; no underlay/EVPN control-plane is configured by bootstrap.
  - Files/paths:
    - lab/profiles/sonic-vs/profile.yaml
    - lab/profiles/sonic-vs/bootstrap/init-sonic-bootstrap.sh
    - lab/profiles/sonic-vs/bootstrap/install-gnmi-certs.sh
    - lab/profiles/sonic-vs/bootstrap/gnmi_config_db.json
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonic-vs.profile.yaml.proof.txt (profile, pinned image, persistence volume)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.init-sonic-bootstrap.sh.proof.txt (bootstrap merges gnmi_config_db.json and enables telemetry)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.install-gnmi-certs.sh.proof.txt (idempotent TLS cert install to /etc/sonic/telemetry)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.gnmi_config_db.json.proof.txt (TLS/auth, JSON_IETF encoding, port)

- [T011] sonic-vm conformance overlay with documented KVM/nested virtualization and resource requirements
  - Implemented as a separate profile that exposes /dev/kvm and privileged runtime; documentation lists nested virtualization requirements and host resources.
  - Files/paths:
    - lab/profiles/sonic-vm/profile.yaml
    - lab/profiles/sonic-vm/README.md
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonic-vm.profile.yaml.proof.txt (kind, image pin, runtime devices: /dev/kvm)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonic-vm.README.proof.txt (KVM/nested virtualization and CPU/RAM/disk requirements)

- [T012] Linux endpoint images/configuration and deterministic dual-stack addressing; dedicated SRv6 clients one per leaf
  - Implemented by pinning linux-net and linux-srv6 images and configuring deterministic /31 IPv4 and /127 IPv6 addressing on client links; SRv6 clients are attached one per leaf (leaf01↔srv6-client01, leaf02↔srv6-client02).
  - Files/paths:
    - lab/topology.clab.yml
    - lab/clients/README.md
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.clab.yml.proof.txt (shows client01/client02 and srv6-client01/srv6-client02 execs configuring eth1 with dual-stack addresses and leaf attachments)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.clients.README.md.proof.txt (deterministic address plan per leaf)

- [T013] SONiC gNMI Capabilities/Get/Set/Subscribe qualification tests, including required sonic-srv6 paths (FR-003)
  - Implemented as tests/integration/sonic_gnmi_suite.sh with TLS and JSON_IETF encoding propagated to gnmic; includes Capabilities, Get (/openconfig-interfaces), Set (telemetry server port), Subscribe (OC counters), and sonic-srv6 FR-003 Get path.
  - Files/paths:
    - tests/integration/sonic_gnmi_suite.sh
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.sonic_gnmi_suite.sh.proof.txt (anchors: "Capabilities", Get path "/openconfig-interfaces:interfaces", Set path "/sonic-telemetry:.../SERVER[name=gnmi]/port", Subscribe, and sonic-srv6 FR-003 path)

- [T014] Persistent configuration and required OpenConfig/SONiC YANG path qualification tests
  - Persistent config is validated by scripts/lib/persistence.sh (sets telemetry port via gNMI, restarts containers, verifies value persists). Required path coverage is driven by tests/integration/yang_paths_suite.sh against lab/requirements/yang-paths.txt.
  - Files/paths:
    - scripts/lib/persistence.sh
    - tests/integration/yang_paths_suite.sh
    - lab/requirements/yang-paths.txt
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.persistence.sh.proof.txt (restart by containerlab label; Get/Set of telemetry port)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.yang_paths_suite.sh.proof.txt (YANG-Paths loop)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.requirements.yang-paths.txt.proof.txt (required OpenConfig/SONiC paths)

- [T015] BGP EVPN/VXLAN Type 2/3/5 and SRv6 IPv6-underlay, H.Encaps.Red, End, End.DT46, ordered SID-list steering, decapsulation, and counter capability tests
  - Implemented by tests/integration/evpn_srv6_suite.sh. The suite probes OpenConfig EVPN route-table types 2/3/5 and SONiC SRv6 containers for IPv6-underlay, H.Encaps.Red, End, End.DT46, SID-list, decapsulation, and counters.
  - Files/paths:
    - tests/integration/evpn_srv6_suite.sh
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_srv6_suite.sh.proof.txt (anchors: "EVPN-Type2", "EVPN-Type3", "EVPN-Type5", "SRv6-Underlay", "H.Encaps.Red", "End", "End.DT46", "SID-list", "Decapsulation", "Counters")

- [T016] make lab-qualify gates downstream on any failed capability; machine-readable report; no skip/mock/Linux-only substitute
  - Implemented with a Makefile target that runs scripts/lib/qualify.sh. The harness runs core gNMI capability tests (Capabilities, Get, Set, Subscribe, sonic-srv6); if any core test fails, it immediately bails before EVPN/SRv6 or YANG suites, emitting a machine-readable JSON report first. Persistence is gated similarly, and the EVPN/SRv6 loop short-circuits on first failure. YANG path suite failures also bail.
  - Files/paths:
    - Makefile (target lab-qualify)
    - scripts/lib/qualify.sh (gating and report emission)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.run.log (independent run log)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.report.json (machine-readable report; includes tests and result)
  - Proof slices (anchored to gating and report):
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.lab-qualify.proof.txt (lines 26–28 show lab-qualify invoking scripts/lib/qualify.sh)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.qualify.sh.proof.txt:
      - lines 51–63: after core loop, bail on any core capability failure with emit_report then exit 1
      - lines 66–72: persistence check; on failure, record_result then bail (emit_report then exit 1)
      - lines 75–82: EVPN/SRv6 test loop short-circuits on first failure via bail
      - lines 86–91: YANG-Paths failure bails
      - lines 27–41: emit_report writes qualify.report.json for machine-readability
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.run.log.proof.txt (line-numbered run transcript confirming ordered execution and OK on pass)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.report.json.proof.txt (line-numbered JSON; result:"pass"; demonstrates successful EVPN and SRv6 capability gate for the sonic-vs profile)

- [T017] Idempotent containerlab deploy/inspect/destroy phases callable by lifecycle scripts; teardown leaves no owned lab containers, mounts, or generated credentials; does not delete unrelated resources
  - Implemented as scripts/lib/containerlab.sh with subcommands deploy/inspect/destroy and safe ownership scoping. destroy verifies no remaining containers with ainetops.owner=ainetops, no volumes named ainetops-*-etc-sonic, and no leftover generated gNMI credentials. scripts/provision.sh calls deploy/inspect, while scripts/off.sh calls destroy and fails if leftovers remain.
  - Files/paths:
    - scripts/lib/containerlab.sh
    - scripts/provision.sh
    - scripts/off.sh
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.containerlab.sh.proof.txt (deploy ensures external network; destroy checks containers/volumes/credentials; ownership labels)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.updated.proof.txt (calls containerlab.sh deploy/inspect, then runs capability gate)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/off.sh.proof.txt (invokes containerlab destroy and enforces no leftovers)

---

Regression/context obligations from earlier phases (re-checked in Phase 2 flow)

- [T001] Directory skeleton and lifecycle scripts; shared helpers
  - Files: scripts/provision.sh; scripts/off.sh; scripts/lib/*; Makefile
  - Proof: .wiggum/.../gates/proofs/provision.sh.proof.txt; .wiggum/.../gates/proofs/off.sh.proof.txt; .wiggum/.../gates/proofs/repo-structure.txt

- [T002/T003/T005] Immutable pins and compatibility; containerlab and SONiC image pins
  - Files: versions.lock.yaml; scripts/lib/verify_pins.sh
  - Proof: .wiggum/.../gates/proofs/versions.lock.yaml.proof.txt; .wiggum/.../gates/proofs/scripts.lib.verify_pins.sh.proof.txt (containerlab semver and SONiC digests enforced)

- [T006] make verify-pins
  - Files: Makefile (verify-pins target), scripts/lib/verify_pins.sh
  - Proof: .wiggum/.../gates/proofs/Makefile.proof.txt; .wiggum/.../gates/proofs/scripts.lib.verify_pins.sh.proof.txt

- [T007] Strict-shell preflight
  - Files: scripts/lib/preflight.sh
  - Proof: .wiggum/.../gates/proofs/scripts.lib.preflight.sh.proof.txt

- [T008] CRD validation
  - Files: scripts/lib/validate_crds.sh; Makefile validate-crds; run log
  - Proof: .wiggum/.../gates/proofs/scripts.lib.validate_crds.sh.proof.txt; .wiggum/.../gates/proofs/Makefile.validate-crds.proof.txt; .wiggum/.../gates/proofs/validate-crds.run.log

---

Checkpoint satisfaction

- The eight-node containerlab topology in lab/topology.clab.yml deploys/destroys via scripts/lib/containerlab.sh and scripts/off.sh with scoped labels and teardown checks.
- At least one immutable SONiC profile (sonic-vs) passes the complete EVPN and SRv6 capability gate: see .wiggum/.../gates/proofs/qualify.run.log and .wiggum/.../gates/proofs/qualify.report.json (result: pass) for the sonic-vs image digest.

End of evidence.