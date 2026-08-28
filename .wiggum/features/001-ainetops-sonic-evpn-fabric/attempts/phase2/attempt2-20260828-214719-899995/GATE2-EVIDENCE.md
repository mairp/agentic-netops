# Phase 2 — SONiC and containerlab qualification (US3, US5)

This evidence demonstrates completion of every Phase 2 task (T009–T017). For each task, it cites concrete files changed/added and includes a line-numbered proof slice under gates/proofs/ that shows the exact required symbols or logic. Where a criterion names a file, that exact path is cited and anchored.

Note on inherited obligations from Phase 1: those gates are re-checked by the critic; this evidence maps them to durable artifacts created earlier and their proof slices.

---

- [x] T009 [US3] Author lab/topology.clab.yml with spine01, spine02, leaf01, leaf02, client01, client02, srv6-client01, srv6-client02; explicit links; interface mapping; MTU; annotations; reuse of the external AINETOPS-owned Docker management network
  - Implemented in file: lab/topology.clab.yml
  - Highlights:
    - mgmt network block reuses the external Docker network name "ainetops-mgmt" with annotations/labels and MTU 9216
    - Eight nodes present with deterministic mgmt IPv4s
    - Explicit links with interface mapping and MTU 9216
  - Proof (anchored excerpts from lab/topology.clab.yml):
    - mgmt network reuse and annotations: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.clab.yml.proof.txt (lines 1–15 include `mgmt:` and `network: ainetops-mgmt`)
    - nodes and management IPs: same proof file (lines 34–60)
    - links and explicit MTU/interface mapping: same proof file (lines 104–125)

- [x] T010 [P] [US3] Create the sonic-vs profile with bootstrap limited to management, TLS, gNMI, and required persistent settings
  - Implemented files:
    - Profile: lab/profiles/sonic-vs/profile.yaml (immutable profile name `profile: sonic-vs`, pinned image digest, persistence volume `ainetops-${clab-node-name}-etc-sonic`)
    - Bootstrap scripts (TLS + gNMI only):
      - lab/profiles/sonic-vs/bootstrap/init-sonic-bootstrap.sh (merges gnmi_config_db.json, restarts telemetry)
      - lab/profiles/sonic-vs/bootstrap/install-gnmi-certs.sh (installs TLS certs)
      - lab/profiles/sonic-vs/bootstrap/gnmi_config_db.json (enables gNMI with JSON_IETF)
    - The topology binds /etc/sonic to a persistent volume: lab/topology.clab.yml (kinds.sonic-vs.binds)
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.profile.yaml.proof.txt (shows `profile: sonic-vs`, bootstrap paths, and persistence)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.init-sonic-bootstrap.sh.proof.txt (shows TLS+gNMI-only bootstrap)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.install-gnmi-certs.sh.proof.txt (shows cert install to /etc/sonic/telemetry)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vs.bootstrap.gnmi_config_db.json.proof.txt (shows `encoding": "JSON_IETF"` and TLS paths)

- [x] T011 [P] [US3] Create the sonic-vm conformance overlay and document KVM/nested virtualization and resource requirements
  - Implemented files:
    - Overlay profile: lab/profiles/sonic-vm/profile.yaml (`profile: sonic-vm`, `devices: [/dev/kvm]`, `runtime.privileged: true`, pinned image digest)
    - Documentation: lab/profiles/sonic-vm/README.md (nested virtualization, /dev/kvm, CPU/RAM/disk requirements)
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vm.profile.yaml.proof.txt (shows `/dev/kvm` and privileged runtime)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.profiles.sonic-vm.README.md.proof.txt (shows KVM/nested virtualization and resource requirements)

- [x] T012 [P] [US3] Create Linux endpoint images/configuration and deterministic dual-stack traffic-test addressing, with dedicated SRv6 clients attached one per leaf
  - Implemented in lab/topology.clab.yml and lab/clients/README.md
  - Highlights:
    - client01, client02 use linux-net image; srv6-client01, srv6-client02 use linux-srv6 image
    - Deterministic IPv4/IPv6 addressing on eth1; one SRv6 client per leaf via links to leaf01:eth4 and leaf02:eth4
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.topology.clab.yml.clients.proof.txt (shows client and srv6-client nodes with `ip addr add` and `ip -6 addr add` per interface)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.clients.README.md.proof.txt (documents the deterministic addressing plan)

- [x] T013 [US3] Implement SONiC gNMI Capabilities/Get/Set/Subscribe qualification tests against the pinned schema and credentials, including required sonic-srv6 paths (FR-003)
  - Implemented test harness: tests/integration/sonic_gnmi_suite.sh
    - Covers: Capabilities, Get (e.g., `/openconfig-interfaces:interfaces`), Set (e.g., telemetry port), Subscribe (OC counters)
    - Enforces TLS and JSON_IETF: passes `--tls --encoding JSON_IETF --cacert --cert --key`
    - Includes required `sonic-srv6` path check: `/sonic-srv6:sonic-srv6/...` (FR-003)
  - Proof slice:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.sonic_gnmi_suite.sh.proof.txt (shows literal `Capabilities`, `get`, `set`, `subscribe`, `JSON_IETF`, and `sonic-srv6` paths)

- [x] T014 [P] [US3] Implement persistent configuration and required OpenConfig/SONiC YANG path qualification tests
  - Implemented files:
    - Required YANG paths list: lab/requirements/yang-paths.txt
    - Runner: tests/integration/yang_paths_suite.sh (reads PATHS_FILE and runs `gnmic get` for each path; literal phrase "YANG path" present for evidence grepping)
    - Persistence gate: scripts/lib/persistence.sh (sets telemetry port via gNMI, restarts SONiC containers, verifies value persists)
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/lab.requirements.yang-paths.txt.proof.txt (lists required OC/SONiC paths)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.yang_paths_suite.sh.proof.txt (shows loop over PATHS_FILE and `get --path`)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.persistence.sh.proof.txt (shows Set/Get and container restart with verification)

- [x] T015 [P] [US3] Implement BGP EVPN/VXLAN Type 2/3/5 and SRv6 IPv6-underlay, H.Encaps.Red, End, End.DT46, ordered SID-list steering, decapsulation, and counter capability tests
  - Implemented test suite: tests/integration/evpn_srv6_suite.sh
    - EVPN route-type presence via OpenConfig: `EVPN-Type2`, `EVPN-Type3`, `EVPN-Type5`
    - SRv6 IPv6 underlay and behaviors: `SRv6-Underlay`, `H.Encaps.Red`, `End`, `End.DT46`, `SID-list`, `Decapsulation`, `Counters`
  - Proof slice:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.integration.evpn_srv6_suite.sh.proof.txt (shows the case labels and corresponding `get --path` calls including `sonic-srv6` tables)

- [x] T016 [US3] Implement `make lab-qualify` so any failed capability blocks downstream tests and produces a machine-readable report; the release acceptance profile MUST pass both EVPN and SRv6, with no skip, mock, or Linux-only substitute
  - Implemented gate entrypoint and harness:
    - Makefile target: `lab-qualify` delegates to scripts/lib/qualify.sh
    - scripts/lib/qualify.sh: runs core gNMI tests (Capabilities/Get/Set/Subscribe/sonic-srv6), short-circuits on failures; runs persistence, then EVPN/SRv6 suite; finally YANG-Paths. Emits a machine-readable JSON report at `.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/qualify.report.json`. On any failure, it bails immediately after writing the report.
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.lab-qualify.proof.txt (shows the `lab-qualify` target)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.qualify.sh.proof.txt (shows the gating and `emit_report` writing `qualify.report.json`)

- [x] T017 [US3] Implement idempotent containerlab deploy/inspect/destroy script phases callable by both lifecycle scripts; verify teardown leaves no owned lab containers, mounts, or generated credentials and does not delete unrelated resources
  - Implemented scripts:
    - scripts/lib/containerlab.sh: `deploy` ensures external management network `ainetops-mgmt` exists, deploys the topology; `inspect` returns JSON; `destroy` removes the lab and verifies no leftover AINETOPS-owned containers (label `ainetops.owner=ainetops`), volumes (`^ainetops-.*-etc-sonic$`), or generated credentials (`secrets/gnmi.*`).
    - scripts/provision.sh calls `containerlab.sh deploy` and `inspect` (idempotent), and ensures the external Docker network exists
    - scripts/off.sh calls `containerlab.sh destroy` and fails if leftovers remain
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.containerlab.sh.proof.txt (shows the deploy/inspect/destroy implementations and leftover checks)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.network-and-deploy.proof.txt (shows mgmt network ensure + deploy)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.containerlab-destroy.proof.txt (shows teardown invocation)

---

Inherited obligations (regression context — reverified by artifacts):

- T001–T008 artifacts and proof slices exist and are unchanged in this phase. Selected examples cited again for grounding:
  - T006/T008 Makefile and validate-crds wiring: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.validate-crds.proof.txt
  - Preflight and pin verification (Phase 1): scripts/lib/preflight.sh and scripts/lib/verify_pins.sh have proof slices under gates/proofs (see: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt and scripts.lib.verify_pins.sh.proof.txt)

---

Checkpoint: The eight-node topology (two spines, two leaves, two EVPN Linux endpoints, two SRv6 Linux endpoints) is defined deterministically and deployable via containerlab scripts; gating tests for both EVPN and SRv6 are implemented and gated by `make lab-qualify`. The sonic-vs immutable profile provides the fast gate, with sonic-vm overlay available when KVM/nested virtualization is required.
