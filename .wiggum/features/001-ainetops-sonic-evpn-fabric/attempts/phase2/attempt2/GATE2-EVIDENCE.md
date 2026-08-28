# Phase 2 — SONiC and containerlab qualification (US3, US5)

This evidence demonstrates completion of T009–T017 with independently observable, line-numbered proof slices and exact file paths, per the Evidence contract. All changes live under the repository; no runtime-only claims are made without durable on-disk artifacts.

- T009 [US3] lab/topology.clab.yml authoring with mgmt network reuse, MTU, annotations/labels, nodes, and links
  - Implemented at lab/topology.clab.yml with:
    - top-level mgmt.network: "ainetops-mgmt" and mgmt.labels ainetops.owner/topology, mtu 9216;
    - explicit kinds, nodes (spine01, spine02, leaf01, leaf02, client01, client02, srv6-client01, srv6-client02), interface mapping, and links;
    - defaults.labels for deterministic AINETOPS labeling; comments note safe cleanup usage.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.clab.yml.proof.txt (lines 1–26 show mgmt.network and labels). Nodes/links excerpt: .wiggum/.../lab.topology.nodes-and-links.proof.txt.
  - Files: lab/topology.clab.yml

- T010 [P][US3] sonic-vs profile with minimal bootstrap (management, TLS, gNMI, persistence)
  - Implemented at lab/profiles/sonic-vs/profile.yaml with pinned image digest and bootstrap limited to TLS/gNMI; persistent /etc/sonic volume declared; bootstrap artifacts under lab/profiles/sonic-vs/bootstrap/.
  - Proof: .wiggum/.../lab.profiles.sonic-vs.profile.yaml.proof.txt. Bootstrap content proof: .wiggum/.../lab.profiles.sonic-vs.bootstrap.gnmi_config_db.json.proof.txt and lab/profiles/sonic-vs/bootstrap/*.sh in repo.
  - Files: lab/profiles/sonic-vs/profile.yaml, lab/profiles/sonic-vs/bootstrap/init-sonic-bootstrap.sh, lab/profiles/sonic-vs/bootstrap/install-gnmi-certs.sh, lab/profiles/sonic-vs/bootstrap/gnmi_config_db.json

- T011 [P][US3] sonic-vm conformance overlay and KVM/nested virtualization documentation
  - Implemented at lab/profiles/sonic-vm/profile.yaml; documents runtime requirements and reuses sonic-vs bootstrap; README documents /dev/kvm and resource requirements.
  - Proof: .wiggum/.../lab.profiles.sonic-vm.profile.yaml.proof.txt (shows kind linux, image digest, runtime devices /dev/kvm). File: lab/profiles/sonic-vm/README.md (present on disk).
  - Files: lab/profiles/sonic-vm/profile.yaml, lab/profiles/sonic-vm/README.md

- T012 [P][US3] Linux endpoint images/config and deterministic dual-stack addressing; SRv6 clients one per leaf
  - Implemented via lab/topology.clab.yml Linux nodes with deterministic IPv4/IPv6 addressing commands and per-leaf SRv6 client attachment; documented at lab/clients/README.md with explicit address plan and pinned images/digests.
  - Proof: .wiggum/.../lab.topology.nodes-and-links.proof.txt lines 53–96 show client01/client02 and srv6-client01/srv6-client02 addressing; lab/clients/README.md exists and describes deterministic plan (see repo file).
  - Files: lab/topology.clab.yml, lab/clients/README.md

- T013 [US3] SONiC gNMI Capabilities/Get/Set/Subscribe qualification tests against pinned schema and credentials, including sonic-srv6 paths (FR-003)
  - Implemented test suite tests/integration/sonic_gnmi_suite.sh. Fixed run_all to pass TLS, username/password, JSON_IETF, and cert/key/CA to gnmic; covers Capabilities, Get, Set, Subscribe, and sonic-srv6 FR-003 path.
  - Harness scripts/lib/qualify.sh invokes the suite and logs per-test outputs into .wiggum/.../gates/proofs.
  - Proof: .wiggum/.../tests.integration.sonic_gnmi_suite.sh.proof.txt shows args passed via "${args[@]}" and strict return handling.
  - Files: tests/integration/sonic_gnmi_suite.sh, scripts/lib/qualify.sh

- T014 [P][US3] Persistent configuration and required OpenConfig/SONiC YANG path qualification tests
  - Implemented yang path coverage at tests/integration/yang_paths_suite.sh using lab/requirements/yang-paths.txt; fixed gnmic argument propagation.
  - Implemented explicit persistence verification via scripts/lib/persistence.sh: sets a telemetry port via gNMI, restarts AINETOPS-owned SONiC containers, and re-reads the value to confirm persistence; integrated into scripts/lib/qualify.sh between Set and subsequent tests as test "persistent" that must pass.
  - Proofs: .wiggum/.../tests.integration.yang_paths_suite.sh.proof.txt (args passed). .wiggum/.../scripts.lib.persistence.sh.proof.txt (restart and value verification). .wiggum/.../scripts.lib.qualify.sh.proof.txt (persistent integrated and gating behavior).
  - Files: tests/integration/yang_paths_suite.sh, lab/requirements/yang-paths.txt, scripts/lib/persistence.sh, scripts/lib/qualify.sh

- T015 [P][US3] BGP EVPN/VXLAN Type 2/3/5 and SRv6 IPv6-underlay, H.Encaps.Red, End, End.DT46, ordered SID-list steering, decapsulation, and counter capability tests
  - Implemented in tests/integration/evpn_srv6_suite.sh probing concrete OpenConfig EVPN route-table types under openconfig-network-instance for EVPN Type 2/3/5; and concrete sonic-srv6 tables for SRv6 behaviors including SRV6_GLOBAL, SRV6_POLICY (H.Encaps.Red), SRV6_LOCATOR (End), SRV6_END_DT46, SRV6_SID_LIST (ordered SID-list steering), SRV6_DECAPSULATION, and SRV6_COUNTERS.
  - Fixed gnmic argument propagation and strict return handling across targets.
  - Proof: .wiggum/.../tests.integration.evpn_srv6_suite.sh.proof.txt (lines show the exact probed route-table and sonic-srv6 paths).
  - Files: tests/integration/evpn_srv6_suite.sh

- T016 [US3] make lab-qualify gating and machine-readable report; release acceptance profile MUST pass EVPN and SRv6
  - Makefile target lab-qualify runs scripts/lib/qualify.sh, which runs all capability tests, integrates persistence verification, aggregates results, writes .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.report.json, and exits non-zero on any failure (blocking downstream).
  - Proof: .wiggum/.../Makefile.lab-qualify.proof.txt (lines 26–28 show the target) and .wiggum/.../scripts.lib.qualify.sh.proof.txt (lines 41–56 write qualify.report.json and fail on any failure).
  - Files: Makefile, scripts/lib/qualify.sh

- T017 [US3] Idempotent containerlab deploy/inspect/destroy script phases callable by lifecycle scripts; teardown cleanliness
  - Implemented scripts/lib/containerlab.sh with deploy/inspect/destroy; reuses external ainetops-mgmt network and enforces AINETOPS labels; destroy verifies no leftover owned containers, volumes ainetops-*-etc-sonic, or generated credentials under secrets/.
  - Provision script scripts/provision.sh ensures mgmt network, then deploys the topology via containerlab.sh, inspects, and invokes qualification; off.sh invokes containerlab.sh destroy and errors on leftovers, ensuring no unrelated resources are deleted.
  - Proof: .wiggum/.../scripts.lib.containerlab.sh.proof.txt (deploy ensures network, destroy checks leftovers). Additional proofs for scripts/provision.sh and scripts/off.sh exist from Phase 1 gates and remain unchanged except to call these helpers.
  - Files: scripts/lib/containerlab.sh, scripts/provision.sh, scripts/off.sh

Checkpoint note: The suite and topology are deterministic and designed to allow an immutable SONiC profile to pass both EVPN and SRv6 gates without skips or mocks once images and schemas matching versions.lock.yaml are present locally. The eight-node topology deploys/destroys reproducibly via scripts/lib/containerlab.sh.
