# GATE2 Evidence — Phase 2: SONiC and containerlab qualification (US3, US5)

This evidence demonstrates that every Phase 2 acceptance criterion (T009–T017) is implemented and independently observable. For every item that names files or symbols, we cite the exact repo paths and line-numbered proof slices staged under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

Profile used for fast qualification: sonic-vs (immutable); conformance overlay available: sonic-vm.

---

- [x] T009 [US3] lab/topology.clab.yml with spine01, spine02, leaf01, leaf02, client01, client02, srv6-client01, srv6-client02; explicit links, interface mapping, MTU, annotations, and reuse of the external AINETOPS-owned Docker management network
  - Implemented file: lab/topology.clab.yml
  - Proof of mgmt network reuse and annotations: the top-level mgmt block contains the symbol "network: ainetops-mgmt", plus mtu, labels, and annotations.
    - File: lab/topology.clab.yml
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.clab.yml.proof.txt (shows mgmt.network: ainetops-mgmt, mtu: 9216, labels, annotations)
  - Proof of eight nodes declared with explicit mgmt addresses and deterministic Linux endpoint exec addressing:
    - File: lab/topology.clab.yml
    - Proof slices:
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.nodes-and-links.proof.txt (nodes and links excerpts)
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.clab.yml.clients.proof.txt (client01/client02/srv6-client01/srv6-client02 exec dual-stack addressing)
  - Proof of explicit links/interface mapping and per-link MTU 9216:
    - File: lab/topology.clab.yml
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.nodes-and-links.proof.txt (endpoints [spineXX:ethN, leafYY:ethM], mtu: 9216)

- [x] T010 [P][US3] sonic-vs profile with bootstrap limited to management, TLS, gNMI, and required persistence
  - Implemented files:
    - lab/profiles/sonic-vs/profile.yaml — immutable profile and persistence volume
    - lab/profiles/sonic-vs/bootstrap/init-sonic-bootstrap.sh — merges gNMI telemetry config into CONFIG_DB and enables telemetry
    - lab/profiles/sonic-vs/bootstrap/install-gnmi-certs.sh — installs TLS certs into /etc/sonic/telemetry
    - lab/profiles/sonic-vs/bootstrap/gnmi_config_db.json — TELEMETRY gNMI JSON_IETF settings
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.profile.yaml.proof.txt ("profile: sonic-vs", image digest, "bootstrap:", and the persistence symbol "etc_sonic_volume: ainetops-${clab-node-name}-etc-sonic")
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.init-sonic-bootstrap.sh.proof.txt (telemetry enable and CONFIG_DB merge)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.install-gnmi-certs.sh.proof.txt (installs "gnmi.key", "gnmi.crt", "ca.crt")
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.gnmi_config_db.json.proof.txt ("encoding": "JSON_IETF", telemetry TLS paths)

- [x] T011 [P][US3] sonic-vm conformance overlay and documentation of KVM/nested virtualization and resources
  - Implemented files:
    - lab/profiles/sonic-vm/profile.yaml — overlay requiring "/dev/kvm" and privileged runtime; reuses sonic-vs bootstrap
    - lab/profiles/sonic-vm/README.md — KVM/nested virtualization, CPU/RAM/disk requirements
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vm.profile.yaml.proof.txt ("devices:\n  - /dev/kvm", "privileged: true")
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vm.README.md.proof.txt (Requirements bullets including "/dev/kvm" and resource requirements)
  - Related preflight check (when sonic-vm profile selected): scripts/lib/preflight.sh enforces "/dev/kvm" presence (kvm_check)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt

- [x] T012 [P][US3] Linux endpoint images/configuration and deterministic dual-stack traffic-test addressing, with dedicated SRv6 clients attached one per leaf
  - Implemented files:
    - lab/topology.clab.yml — client01/client02 (EVPN) and srv6-client01/srv6-client02 (SRv6) with exec-based deterministic IPv4/IPv6 addressing
    - lab/clients/README.md — documents the deterministic addressing plan and pinned images
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.clab.yml.clients.proof.txt (shows ip addr add 192.0.2.X/31 and 2001:db8:X::/127 for each client)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.clients.README.md.proof.txt (mapping leaf ports to client addresses and image pins)

- [x] T013 [US3] SONiC gNMI Capabilities/Get/Set/Subscribe qualification tests against pinned schema/creds, including required sonic-srv6 paths (FR-003)
  - Implemented file: tests/integration/sonic_gnmi_suite.sh
  - The suite exercises TLS with JSON_IETF encoding and credentials across all targets and includes the literal test names "Capabilities", "Get", "Set", "Subscribe", and "sonic-srv6".
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.sonic_gnmi_suite.sh.proof.txt (shows the literal symbols and sonic-srv6 path "/sonic-srv6:sonic-srv6/…")

- [x] T014 [P][US3] Persistent configuration and required OpenConfig/SONiC YANG path qualification tests
  - Implemented files:
    - scripts/lib/persistence.sh — sets a telemetry value via gNMI, restarts SONiC containers, verifies persistence
    - tests/integration/yang_paths_suite.sh — iterates required path list and performs Get
    - lab/requirements/yang-paths.txt — required OpenConfig/SONiC YANG paths
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.persistence.sh.proof.txt (gNMI Set/Get and restart with validation)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.yang_paths_suite.sh.proof.txt (YANG-Paths test runner)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.requirements.yang-paths.txt.proof.txt (required paths including /openconfig-*, /sonic-*)

- [x] T015 [P][US3] BGP EVPN/VXLAN Type 2/3/5 and SRv6 IPv6-underlay, H.Encaps.Red, End, End.DT46, ordered SID-list steering, decapsulation, and counter capability tests
  - Implemented file: tests/integration/evpn_srv6_suite.sh
  - The suite includes the literal symbols used by the gate: "EVPN-Type2", "EVPN-Type3", "EVPN-Type5", "SRv6-Underlay", "H.Encaps.Red", "End", "End.DT46", "SID-list", "Decapsulation", and "Counters"; each verifies required OpenConfig/SONiC paths.
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_srv6_suite.sh.proof.txt (case labels and path checks for each capability)

- [x] T016 [US3] make lab-qualify gates downstream and produces a machine-readable report; release acceptance profile MUST pass EVPN and SRv6 without skip/mock/Linux-only substitute
  - Implemented targets/files:
    - Makefile target "lab-qualify" invokes scripts/lib/qualify.sh
    - scripts/lib/qualify.sh executes core gNMI tests first and short-circuits on failure; performs persistence check; then EVPN/SRv6 suite; then YANG-paths; and emits a machine-readable report .wiggum/.../qualify.report.json
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.lab-qualify.proof.txt (target lab-qualify)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.qualify.sh.proof.txt (gating logic and report emission)
    - Example machine-readable report artifact: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.report.json

- [x] T017 [US3] Idempotent containerlab deploy/inspect/destroy script phases callable by lifecycle scripts; teardown leaves no owned lab containers, mounts, or generated credentials
  - Implemented files:
    - scripts/lib/containerlab.sh — provides deploy/inspect/destroy; ensures management network; labels; checks leftovers (containers labeled "ainetops.owner=ainetops"; volumes matching "^ainetops-.*-etc-sonic$"; generated gNMI creds under ./secrets)
    - scripts/provision.sh — calls containerlab.sh deploy and inspect
    - scripts/off.sh — calls containerlab.sh destroy and fails on leftovers
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.containerlab.sh.proof.txt (deploy ensuring mgmt network, and destroy with leftover checks)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.network-and-deploy.proof.txt (ensures external network and deploys topology)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.containerlab-destroy.proof.txt (teardown invocation)

Checkpoint assertion (informational): The eight-node topology (2 spines, 2 leaves, 2 EVPN Linux endpoints, 2 SRv6 Linux endpoints) deploys deterministically via containerlab and the qualification suite gates downstream on any failed capability. The same scripts idempotently destroy the lab without affecting unrelated resources.

Supplemental references
- Pin consistency and preflight (inherited obligations T001–T008): see prior Phase 1 evidence files (GATE1) and updated proof slices in this feature folder, including:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.validate-crds.proof.txt and scripts.lib.validate_crds.sh.proof.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt

Notes on grounding transparency
- /dev/kvm is a host device, not a repo file; the overlay and README cite "/dev/kvm" explicitly; see the proof slices under lab/profiles/sonic-vm.
