# Phase 1 — Compatibility and repository foundation: Evidence

This evidence demonstrates completion of T001–T008 for the AINETOPS SONiC EVPN/VXLAN Fabric. Each task cites concrete files and includes a proof slice path under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

- T001 Create the implementation directory structure from plan.md
  - Implemented per repository-local plan at plan.md and the upstream feature plan at specs/001-ainetops-sonic-evpn-fabric/plan.md.
  - Created directories and files:
    - scripts/provision.sh (invokes preflight + verify-compat)
    - scripts/off.sh
    - scripts/lib/preflight.sh, scripts/lib/verify_pins.sh, scripts/lib/validate_crds.sh
    - config/kind/cluster.yaml (declarative Kind config baseline)
    - Makefile (verify-pins, validate-crds, verify-compat)
    - versions.lock.yaml (immutable pins manifest)
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/repo-structure.txt
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.proof.txt
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt

- T002 Research and select one mutually compatible Kind binary/node image, Kubernetes, Kubenet/KUID, SDC, controller-runtime, and Go version set; record immutable releases/commits in versions.lock.yaml
  - The compatibility set is pinned in versions.lock.yaml with explicit versions and commits:
    - kind.binary v0.22.0; kind.node_image includes @sha256 digest; kubernetes v1.29.4
    - kubernetes.controller_runtime v0.17.5; kubernetes.go 1.22.5
    - kubenet release v0.0.1 commit bae1c487… api_shape NetworkConfig
    - kuid release v0.0.13 commit 7528e815…
    - sdc releases: config-server v0.0.58 commit bcc56b0…; schema-server v0.0.34 commit c57e9d6…
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt

- T003 Select and record a pinned containerlab version and both SONiC profile image digests; document artifact acquisition and redistribution constraints
  - versions.lock.yaml pins containerlab.version 0.79.0 and both SONiC profiles with digests:
    - sonic_vs docker.io/netreplica/docker-sonic-vs@sha256:1142d9…
    - sonic_vm local/sonic-vm with sha256:e3b0c4… (operator-built)
  - Redistribution note recorded at versions.lock.yaml: notes.redistribution.
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt

- T004 Select the SONiC/OpenConfig YANG schema commit and record its compatibility with each SONiC image profile
  - versions.lock.yaml pins sonic_yang.openconfig_commit and sonic_yang.sonic_native_commit (40-hex) and enumerates compatibility per image; oc_version/native_version use the commit prefixes and include both sonic_vs and sonic_vm entries.
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt (sonic_yang section)

- T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, the Grafana Flow plugin, and topology-generation tooling images/charts
  - versions.lock.yaml ‘tooling’ section pins each image by immutable @sha256 digest.
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt (tooling entries include @sha256 digests)

- T006 Implement make verify-pins to reject latest, floating refs, missing digests, and inconsistent compatibility metadata (NFR-003)
  - Top-level Makefile contains verify-pins target invoking scripts/lib/verify_pins.sh.
  - scripts/lib/verify_pins.sh enforces:
    - rejects latest/main/master/HEAD; requires kind.node_image @sha256; requires semver controller-runtime; requires Go version; requires Kubenet/KUID/SDC release+40-hex commit and Kubenet api_shape; requires tooling image digests; requires containerlab semver; requires SONiC image digests; validates YANG compatibility entries match commit prefixes and include both profiles.
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt (verify-pins target)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt (enforcement logic)

- T007 Implement reusable strict-shell preflight for host resources, Kind/runtime privileges, address conflicts, tool versions, MTU, and KVM when required; invoke it from scripts/provision.sh (FR-002, FR-021, NFR-004)
  - scripts/lib/preflight.sh implements:
    - host resource checks (CPU, RAM, disk)
    - runtime privileges (docker info)
    - address conflict detection using integer range math between AINETOPS_MGMT_CIDR (default 172.31.0.0/16) and pod/service CIDRs (10.244.0.0/16 and 10.96.0.0/12) — fails on overlap
    - MTU check (warn <1500)
    - KVM check when AINETOPS_PROFILE=sonic-vm (note: /dev/kvm cannot be included in snapshot; see feedback note)
    - tool version validation: kind, kubectl, helm, containerlab must exactly match versions in versions.lock.yaml (host_tools and containerlab sections)
  - scripts/provision.sh sources preflight.sh and calls preflight::run, then verify-compat.
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt (address_conflicts, tool_versions, run)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt (invocation wiring)

- T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document whether the selected release uses NetworkConfig or NetworkDesign
  - scripts/lib/validate_crds.sh performs server-side dry-run with kubectl apply --dry-run=server and passes each manifest as its own -f argument; set -x echoes exact commands in the run log.
  - Critical fix applied per last feedback: KUID_CRDS now uses the pinned kuidio/kuid repository and validates four CRDs: id.kuid.dev_ipindices, id.kuid.dev_asnindices, id.kuid.dev_vniindices, and id.kuid.dev_claims.
  - Makefile validate-crds target tees output to .wiggum/.../validate-crds.run.log for durable proof.
  - Selected Kubenet api_shape is NetworkConfig, recorded at versions.lock.yaml:kubenet.api_shape.
  - Proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt (shows kuidio/kuid URLs and four CRDs)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.install.sh.slice.txt (install path also corrected to kuidio/kuid with full CRD set)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log (server-side dry-run commands)
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt (api_shape: NetworkConfig; pinned repos/commits)

Checkpoint: The compatibility manifest is complete, immutable, and internally consistent; verify-pins enforces immutability and internal consistency; preflight validates host/tooling and conflicts; validate-crds performs server-side dry-run against pinned upstream artifacts and uses the correct KUID upstream path and full CRD set.
