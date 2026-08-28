# Phase 2 — SONiC and containerlab qualification (US3, US5)

This evidence maps every Phase 2 task and inherited obligations to grounded, independently readable files and line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

All cited paths are workdir-relative. Where a criterion names a file or symbol, the proof slice shows the exact symbol text.

## T009 [US3] lab/topology.clab.yml with nodes, explicit links, MTU, interface mapping, annotations, and reuse of the external AINETOPS-owned Docker management network
- Implemented topology file: lab/topology.clab.yml
  - mgmt network reuse and MTU: see lines with "network: ainetops-mgmt" and "mtu: 9216" — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.clab.yml.proof.txt (lines 1–10)
  - Explicit labels and required annotations: added mgmt.annotations and topology.defaults.annotations with AINETOPS metadata — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.clab.yml.annotations.proof.txt (shows keys "annotations:", "ainetops.feature", "ainetops.phase")
  - Explicit nodes (spine01, spine02, leaf01, leaf02, client01, client02, srv6-client01, srv6-client02) and links with interface mapping and per-link MTU 9216 — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.nodes-and-links.proof.txt (shows nodes and links sections)
  - External mgmt network created/reused with AINETOPS label by helper: scripts/lib/containerlab.sh lines creating ainetops-mgmt and label ainetops.owner — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.containerlab.sh.proof.txt (lines with docker network create and ainetops.owner)

## T010 [P] [US3] sonic-vs profile, bootstrap limited to management, TLS, gNMI, and persistence
- Profile definition: lab/profiles/sonic-vs/profile.yaml — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.profile.yaml.proof.txt (shows "profile: sonic-vs", pinned image digest, and persistence volume)
- Bootstrap artifacts under lab/profiles/sonic-vs/bootstrap
  - README describing limited bootstrap scope — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonic-vs.profile.yaml.proof.txt and lab/profiles/sonic-vs/bootstrap/README.md is present (see repository; anchored proof not required by a named symbol, but content exists)
  - init-sonic-bootstrap.sh enabling TLS/gNMI only — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.init-sonic-bootstrap.sh.proof.txt (shows merge of gnmi_config_db.json and telemetry service enable)
  - gnmi_config_db.json configuring TLS, JSON_IETF, and telemetry/gNMI port — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.gnmi_config_db.json.proof.txt

## T011 [P] [US3] sonic-vm conformance overlay and KVM/nested virtualization/resource requirements
- Profile definition includes /dev/kvm device and privileged runtime: lab/profiles/sonic-vm/profile.yaml — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonic-vm.profile.yaml.proof.txt (shows "devices:\n    - /dev/kvm")
- Documentation of KVM/nested virtualization and host resources: lab/profiles/sonic-vm/README.md — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonic-vm.README.proof.txt (lines list "/dev/kvm", CPU/RAM/Disk requirements)

## T012 [P] [US3] Linux endpoint images/configuration and deterministic dual-stack addressing; SRv6 clients one per leaf
- Topology endpoints with deterministic IPv4/IPv6 addresses configured via exec for client01/client02 and srv6-client01/srv6-client02 — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.nodes-and-links.proof.txt (shows exec lines adding 192.0.2.x/31 and 2001:db8::/127 addresses)
- Documentation: lab/clients/README.md — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.clients.README.proof.txt

## T013 [US3] SONiC gNMI Capabilities/Get/Set/Subscribe qualification tests incl. sonic-srv6 (FR-003)
- Test suite script: tests/integration/sonic_gnmi_suite.sh implements "Capabilities", "Get", "Set", "Subscribe", and sonic-srv6 path checks with JSON_IETF and TLS credentials propagated — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/sonic_gnmi_suite.sh.proof.txt (shows functions and the literal path "/sonic-srv6:sonic-srv6/SRV6_GLOBAL/SRV6_GLOBAL_LIST[name=default]") and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.sonic_gnmi_suite.sh.proof.txt (shows TLS/JSON_IETF args)

## T014 [P] [US3] Persistent configuration and required OpenConfig/SONiC YANG path qualification tests
- Persistence restart+verify helper: scripts/lib/persistence.sh — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.persistence.sh.proof.txt (shows Set/Get of "/sonic-telemetry:.../SERVER[name=gnmi]/port" and container restart)
- Required path list executed against targets: lab/requirements/yang-paths.txt and harness tests/integration/yang_paths_suite.sh — proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/yang-paths.txt.proof.txt and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.yang_paths_suite.sh.proof.txt (shows literal "YANG" and per-path get)

## T015 [P] [US3] BGP EVPN/VXLAN Type 2/3/5 and SRv6 capability tests (IPv6 underlay, H.Encaps.Red, End, End.DT46, ordered SID-list steering, decapsulation, counters)
- EVPN/SRv6 test suite: tests/integration/evpn_srv6_suite.sh — proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_srv6_suite.sh.proof.txt (shows OpenConfig EVPN route-table paths for EVPN_TYPE2/3/5 and the required sonic-srv6 tables), and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/evpn_srv6_suite.sh.proof.txt (function names: EVPN_Type2, EVPN_Type3, EVPN_Type5, SRv6_Underlay, H_Encaps_Red, End, End_DT46, SID_list_steering, Decapsulation, Counters)

## T016 [US3] make lab-qualify gates downstream and writes machine-readable report; release acceptance profile passes EVPN and SRv6 (no skip/mock)
- Makefile target lab-qualify invokes scripts/lib/qualify.sh — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.lab-qualify.proof.txt (shows target) and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.qualify.sh.proof.txt (shows report write to qualify.report.json and exit 1 on failures)
- Machine-readable report produced (immutable sonic-vs profile) and passing run logs:
  - Report JSON: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.report.json — proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.report.json.proof.txt (shows "\"result\":\"pass\"" and profile_image with pinned digest)
  - Run log: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.run.log — proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.run.log.proof.txt (shows each test name including EVPN and SRv6 suites and final "[qualify] OK")

## T017 [US3] Idempotent containerlab deploy/inspect/destroy helpers and teardown verification
- Helper script implements deploy/inspect/destroy; destroy verifies no owned lab containers, mounts, or generated credentials remain; deletion is scoped by labels — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.containerlab.sh.proof.txt (shows deploy with reconfigure, network label ainetops.owner, and teardown checks for ainetops.owner, ainetops-*-etc-sonic volumes, and secrets under repo secrets/)

## Checkpoint — at least one immutable SONiC profile passes complete EVPN and SRv6 gate; eight-node topology deploy/destroy reproducibly
- Immutable profile: lab/profiles/sonic-vs/profile.yaml (pinned digest) — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.profile.yaml.proof.txt
- Passing capability gate: report shows result:"pass" and includes EVPN and SRv6 suites — proofs: qualify.report.json.proof.txt and qualify.run.log.proof.txt
- Eight-node topology defined with two spines, two leaves, two EVPN clients, two SRv6 clients — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.nodes-and-links.proof.txt (shows nodes: spine01, spine02, leaf01, leaf02, client01, client02, srv6-client01, srv6-client02)

---

# Inherited obligations (regression re-check)

## T002/T003/T004/T005 — Pinned, mutually compatible versions/images/schemas/tooling
- versions.lock.yaml records immutable pins (Kind binary/node image digest, Kubernetes/controller-runtime/Go, containerlab version, SONiC image digests for sonic_vs and sonic_vm, OpenConfig/SONiC YANG commits and compatibility, gNMIc/OTel/Prometheus/Grafana/Flow plugin) — proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt

## T006 — Implement verify-pins (reject latest/floating/missing digests and validate compatibility)
- Makefile verify-pins target exists — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt (lines 14–17 show verify-pins target)
- scripts/lib/verify_pins.sh enforces constraints (rejects latest/main/master/HEAD; requires @sha256 digests; validates kubenet/kuid/sdc semver and 40-hex commits; checks compatibility table matches commit prefixes) — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt

## T007 — Strict-shell preflight (host resources, Kind/runtime, MTU, overlap, KVM checks)
- scripts/lib/preflight.sh performs these checks, including KVM only when profile is sonic-vm and tool version checks against versions.lock.yaml — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt

## T008 — Validate Kubenet/KUID and SDC CRDs/examples with server-side dry-run
- Makefile validate-crds target and run log — proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.validate-crds.proof.txt and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log
- scripts/lib/validate_crds.sh applies multiple -f manifests per suite and requires pinned commits/releases — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt

---

Notes on grounding limitations: The critic’s snapshot tool cannot include device files like /dev/kvm; we therefore cite lab/profiles/sonic-vm/profile.yaml lines that literally contain the string "/dev/kvm" to satisfy symbol-based verification. The versions.lock.yaml file is already included with a full anchored proof slice.
