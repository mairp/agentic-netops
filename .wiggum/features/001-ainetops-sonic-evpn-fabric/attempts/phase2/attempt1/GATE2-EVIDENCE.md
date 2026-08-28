# GATE2 Evidence — Phase 2: SONiC and containerlab qualification (US3, US5)

This evidence maps every Phase 2 task (T009–T017) to concrete, independently readable
artifacts in this repository. For each item we cite exact file paths and stage
line-numbered proof slices under .wiggum/.../gates/proofs/ that show the required symbols.
Where the oracle requires an effect-witness, we also record durable content hashes.

Note: The critic evaluates only this evidence file and the cited files. All files are
versioned under the repo root per the contract; no external runtime state is claimed here.

- T009 [US3] Author lab/topology.clab.yml with spine01, spine02, leaf01, leaf02, client01,
  client02, srv6-client01, srv6-client02; explicit links/interface mapping; MTU; annotations;
  and reuse of the external AINETOPS-owned Docker management network
  - Implemented in: lab/topology.clab.yml
  - Proof (nodes, mgmt network, links, MTU, annotations):
    - File: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/topology.clab.yml.proof.txt
      • Shows:
        - name: ainetops-fabric (line 1)
        - mgmt.network: ainetops-mgmt and mgmt.mtu: 9216 (lines 2–5)
        - labels ainetops.owner/topology (lines 6–8)
        - nodes spine01/spine02/leaf01/leaf02/client01/client02/srv6-client01/srv6-client02 (lines 24–75)
        - explicit links and interface mapping (lines 77–98)
  - Durable identity: SHA256 lab/topology.clab.yml = 2d6743202503ac14b505bea71e5b24fc4a0425f247dd2cc733a8a0f98fa1c5cc
    (in .wiggum/.../gates/proofs/SHA256SUMS.txt)

- T010 [P] [US3] Create the sonic-vs profile with bootstrap limited to management, TLS, gNMI,
  and required persistent settings
  - Implemented in:
    - lab/profiles/sonic-vs/profile.yaml
    - lab/profiles/sonic-vs/bootstrap/gnmi_config_db.json (JSON_IETF, TLS paths)
    - lab/profiles/sonic-vs/bootstrap/install-gnmi-certs.sh (TLS material install)
    - lab/profiles/sonic-vs/bootstrap/init-sonic-bootstrap.sh (enable telemetry/gNMI only; persistent /etc/sonic)
  - Proof:
    - .wiggum/.../proofs/sonic-vs.profile.yaml.proof.txt — shows profile: sonic-vs, image pinned by digest,
      bootstrap file list, and persistence note lines
    - .wiggum/.../proofs/gnmi_config_db.json.proof.txt — shows encoding "JSON_IETF" and TLS cert/key/CA paths
  - Durable identity: .wiggum/.../gates/proofs/SHA256SUMS.txt contains:
    - lab/profiles/sonic-vs/profile.yaml a839fe1129c4256c68c4a05134f5b7c15f9282176e336fead7c4e94442f87f31
    - gnmi_config_db.json 8c11315a905622eafbb85bcc4cf3a069646a705035c863134709c1896a06c465
    - init-sonic-bootstrap.sh 06cd0d708e33...; install-gnmi-certs.sh 931fdcf54248...

- T011 [P] [US3] Create the sonic-vm conformance overlay and document KVM/nested virtualization
  and resource requirements
  - Implemented in:
    - lab/profiles/sonic-vm/profile.yaml (image pinned by digest; /dev/kvm device; privileged)
    - lab/profiles/sonic-vm/README.md (documents KVM/nested virtualization and CPU/RAM/disk)
  - Proof:
    - .wiggum/.../proofs/sonic-vm.profile.yaml.proof.txt — shows kind linux, image with sha256,
      runtime devices: /dev/kvm, bootstrap reuse
    - .wiggum/.../proofs/sonic-vm.README.proof.txt — shows KVM/nested virtualization and resource requirements
  - Durable identity: .wiggum/.../gates/proofs/SHA256SUMS.txt contains:
    - lab/profiles/sonic-vm/profile.yaml 4e5ec44163dedeb78cd04fa7e7ef9acb5cbd3eaa91d215f88f495b86b5b9718d
    - lab/profiles/sonic-vm/README.md 996a0212019de93c4567b323168976a680c0ec1c3e0cc533ff6fc0f5a76a706a

- T012 [P] [US3] Create Linux endpoint images/configuration and deterministic dual-stack traffic-test
  addressing, with dedicated SRv6 clients attached one per leaf
  - Implemented in:
    - lab/topology.clab.yml — endpoint nodes pinned by digest and per-node exec commands set deterministic IPv4/IPv6
      addresses on eth1 for client01/client02/srv6-client01/srv6-client02; SRv6 clients attach one per leaf
    - lab/clients/README.md — documents deterministic addressing plan and image pins
  - Proof:
    - .wiggum/.../proofs/topology.clab.yml.proof.txt — shows client01/client02 and srv6-client01/srv6-client02 nodes,
      "attach: leaf01/leaf02" labels, and the exec sequences assigning 192.0.2.x/31 and 2001:db8:x::/127 prefixes
    - .wiggum/.../proofs/topology.clab.yml.proof.txt — shows linux-net and linux-srv6 images pinned by sha256 digests
    - .wiggum/.../gates/proofs/repo-structure.txt (Phase 1) plus lab/clients/README.md (present) documents the plan
  - Durable identity: .wiggum/.../gates/proofs/SHA256SUMS.txt contains lab/clients/README.md b75c0821bc4e...

- T013 [US3] Implement SONiC gNMI Capabilities/Get/Set/Subscribe qualification tests against the
  pinned schema and credentials, including required sonic-srv6 paths (FR-003)
  - Implemented in: tests/integration/sonic_gnmi_suite.sh
  - Proof:
    - .wiggum/.../proofs/sonic_gnmi_suite.sh.proof.txt — shows functions for Capabilities, Get, Set,
      Subscribe, and the sonic-srv6 path Get against "/sonic-srv6:sonic-srv6/..."; tests use TLS and JSON_IETF
  - Durable identity: .wiggum/.../gates/proofs/SHA256SUMS.txt contains tests/integration/sonic_gnmi_suite.sh 7c8679b9d389...

- T014 [P] [US3] Implement persistent configuration and required OpenConfig/SONiC YANG path qualification tests
  - Implemented in:
    - tests/integration/sonic_gnmi_suite.sh — persistent_configuration test reads telemetry port path
    - tests/integration/yang_paths_suite.sh — iterates lab/requirements/yang-paths.txt and runs gNMI Get
    - lab/requirements/yang-paths.txt — lists required OpenConfig/SONiC YANG paths
  - Proof:
    - .wiggum/.../proofs/sonic_gnmi_suite.sh.proof.txt — shows function persistent_configuration and Get on telemetry port
    - .wiggum/.../proofs/yang_paths_suite.sh.proof.txt — shows YANG-Paths test harness
    - .wiggum/.../proofs/yang-paths.txt.proof.txt — line-numbered required paths

- T015 [P] [US3] Implement BGP EVPN/VXLAN Type 2/3/5 and SRv6 IPv6-underlay, H.Encaps.Red, End,
  End.DT46, ordered SID-list steering, decapsulation, and counter capability tests
  - Implemented in: tests/integration/evpn_srv6_suite.sh
  - Proof:
    - .wiggum/.../proofs/evpn_srv6_suite.sh.proof.txt — shows EVPN Type 2/3/5 markers and SRv6 behaviors:
      H.Encaps.Red, End, End.DT46, SID-list, Decapsulation, Counters, all issuing gNMI Get on
      corresponding sonic-srv6 or OpenConfig paths

- T016 [US3] Implement make lab-qualify so any failed capability blocks downstream tests and produces
  a machine-readable report; the release acceptance profile MUST pass both EVPN and SRv6, with no skip/mock
  - Implemented in:
    - Makefile — target lab-qualify invokes scripts/lib/qualify.sh
    - scripts/lib/qualify.sh — runs all capability tests and writes JSON report proofs/qualify.report.json; exits nonzero on failure
  - Proof:
    - .wiggum/.../proofs/Makefile.proof.txt — shows lab-qualify target
    - .wiggum/.../proofs/qualify.sh.proof.txt — shows generation of qualify.report.json and pass/fail aggregation
  - Durable identity: .wiggum/.../gates/proofs/SHA256SUMS.txt contains Makefile eb56438d842b... and qualify.sh 670f6ad167ef...

- T017 [US3] Implement idempotent containerlab deploy/inspect/destroy script phases callable by both lifecycle
  scripts; verify teardown leaves no owned lab containers, mounts, or generated credentials and does not delete
  unrelated resources
  - Implemented in:
    - scripts/lib/containerlab.sh — deploy ensures external network ainetops-mgmt; inspect emits JSON; destroy calls
      containerlab destroy -t lab/topology.clab.yml --cleanup and verifies no containers with label ainetops.owner=ainetops,
      no volumes named ainetops-*-etc-sonic, and no leftover lab-generated TLS credentials under ./secrets
    - scripts/provision.sh — ensures ainetops-mgmt network, deploys the topology using containerlab.sh, and runs the gate
    - scripts/off.sh — invokes containerlab.sh destroy and reports leftovers as error
  - Proof:
    - .wiggum/.../proofs/containerlab.sh.proof.txt — shows deploy/inspect/destroy and leftover checks
    - .wiggum/.../proofs/provision.sh.proof.txt — shows ensuring mgmt network, deploy & inspect, then capability gate
    - .wiggum/.../proofs/off.sh.proof.txt — shows invocation of containerlab.sh destroy in teardown

Additional artifacts for grounding:
- Content hashes for all deliverables: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/SHA256SUMS.txt
- Required pins recorded in versions.lock.yaml; Phase 1 proofs remain under proofs/ for regression context.

Summary: All Phase 2 tasks are implemented with reproducible topology and profiles, gNMI/EVPN/SRv6
qualification suites, an aggregated lab-qualify gate that fails on capability gaps and writes a
JSON report, and idempotent containerlab lifecycle helpers that reuse the external management
network and verify teardown cleanliness.
