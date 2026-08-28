# Phase 1 — Compatibility and repository foundation: Evidence

This evidence demonstrates completion of T001–T008 for the AINETOPS SONiC EVPN/VXLAN Fabric. For each task, it cites concrete files and line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

- T001 Create the implementation directory structure from plan.md
  - Files and paths created per plan:
    - scripts/provision.sh — sole environment creation/convergence entrypoint
    - scripts/off.sh — sole teardown entrypoint
    - scripts/lib/preflight.sh, scripts/lib/verify_pins.sh, scripts/lib/validate_crds.sh — shared helpers
    - config/kind/cluster.yaml — declarative Kind config
    - Makefile — verify-pins, validate-crds, verify-compat, lab-qualify
    - versions.lock.yaml — immutable compatibility manifest
  - Repo tree proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/repo-structure.txt
  - Script proofs:
    - scripts/provision.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt
    - scripts/off.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.proof.txt
    - scripts/lib/preflight.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
    - scripts/lib/verify_pins.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt
    - scripts/lib/validate_crds.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt
  - Makefile proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt

- T002 Research and select one mutually compatible Kind binary/node image, Kubernetes, Kubenet/KUID, SDC, controller-runtime, and Go version set; record immutable releases/commits in versions.lock.yaml
  - File: versions.lock.yaml — cites exact pins:
    - kind.binary: v0.22.0; kind.node_image: kindest/node@sha256:3abb816a…; kubernetes: v1.29.4
    - kubernetes.controller_runtime: v0.17.5; kubernetes.go: "1.22.5"
    - kubenet.repo, release v0.0.1, commit bae1c4878257194b64b8435208663a9e286547ed, api_shape: NetworkConfig
    - kuid.repo, release v0.0.13, commit 7528e81528c2e9f586b6fe657907424ad93c7ead
    - sdc.core.release v0.31.0; config/schema server pins present
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt

- T003 Select and record a pinned containerlab version and both SONiC profile image digests; document artifact acquisition and redistribution constraints
  - File: versions.lock.yaml — pins containerlab.version and both SONiC profiles with immutable digests:
    - containerlab.version: 0.79.0 (commit 89055fd…)
    - sonic_images.sonic_vs.image and .digest: docker.io/netreplica/docker-sonic-vs@sha256:1142d9e… (digest repeated under .digest)
    - sonic_images.sonic_vm.image: local/sonic-vm and .digest: sha256:b2c77f0a1426e7a93cad0b191f0c04dcf98b3f4b7467348ed550f4b1a706e3d5 (operator-built immutable digest)
    - notes.redistribution documents operator acquisition and no redistribution
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt (search for "containerlab:", "sonic_images:", and "digest: sha256:b2c77f0a1426e7a93cad0b191f0c04dcf98b3f4b7467348ed550f4b1a706e3d5")

- T004 Select the SONiC/OpenConfig YANG schema commit and record its compatibility with each SONiC image profile
  - File: versions.lock.yaml — pins sonic_yang.openconfig_commit and sonic_yang.sonic_native_commit (40-hex), and enumerates compatibility for both images with commit-prefix metadata:
    - sonic_yang.openconfig_commit: f34434149a47aa8ff82ffd32add3aacb7c880af2
    - sonic_yang.sonic_native_commit: cfc766e13eccab4e7603808db3bfa9c5b2dfef17
    - sonic_yang.compatibility includes entries for:
      - image: docker.io/netreplica/docker-sonic-vs@sha256:1142d9e4f763cfb0… with oc_version openconfig@f3443414 and native_version sonic_yang@cfc766e1
      - image: local/sonic-vm@sha256:b2c77f0a1426e7a9… with oc_version openconfig@f3443414 and native_version sonic_yang@cfc766e1
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt (see sonic_yang: and compatibility: lines)

- T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, the Grafana Flow plugin, and topology-generation tooling images/charts
  - File: versions.lock.yaml — tooling section pins each image by immutable @sha256 digest:
    - tooling.gnmic: ghcr.io/openconfig/gnmic@sha256:fd59f5f1…
    - tooling.otel_collector: otel/opentelemetry-collector-contrib@sha256:e07e325e…
    - tooling.prometheus: prom/prometheus@sha256:f20d3127…; tooling.grafana: grafana/grafana@sha256:408afb97…
    - tooling.grafana_flow_plugin: grafana/flow-plugin@sha256:5c9d6b4d…; topology_generator: ghcr.io/ainetops/topology-generator@sha256:9a0b2b0d…
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt (see tooling: block with @sha256 digests)

- T006 Implement make verify-pins to reject latest, floating refs, missing digests, and inconsistent compatibility metadata (NFR-003)
  - File: Makefile — target verify-pins invokes scripts/lib/verify_pins.sh; verify-compat chains verify-pins and validate-crds.
  - File: scripts/lib/verify_pins.sh — enforces:
    - rejects floating refs (latest/main/master/HEAD)
    - requires kind.node_image include @sha256
    - requires semver controller-runtime and Go
    - requires Kubenet/KUID/SDC release+40-hex commit and Kubenet api_shape ∈ {NetworkConfig, NetworkDesign}
    - requires all tooling images have @sha256 digests
    - requires containerlab semver
    - requires SONiC image digests present; builds full image@digest and validates both entries in sonic_yang.compatibility; checks oc/native commit prefixes match oc/native commit pins
  - Proof slices:
    - Makefile → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt (see verify-pins and verify-compat targets)
    - scripts/lib/verify_pins.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt

- T007 Implement reusable strict-shell preflight for host resources, Kind/runtime privileges, address conflicts, tool versions, MTU, and KVM when required; invoke it from scripts/provision.sh (FR-002, FR-021, NFR-004)
  - File: scripts/lib/preflight.sh — implements:
    - host resources (CPU/RAM/disk) → functions preflight::host_resources
    - runtime privileges (docker info) → preflight::runtime_privileges
    - address conflicts (non-overlap of mgmt vs pod/service CIDRs) using integer range math → preflight::address_conflicts
    - MTU check (warn if <1500) → preflight::mtu
    - KVM presence when AINETOPS_PROFILE=sonic-vm → preflight::kvm_check (explicitly mentions /dev/kvm)
    - host tool version checks against versions.lock.yaml (kind, kubectl, helm, containerlab) → preflight::tool_versions
  - File: scripts/provision.sh — sources preflight.sh and invokes preflight::run before verify-compat.
  - Proof slices:
    - scripts/lib/preflight.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
    - scripts/provision.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt

- T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document whether the selected release uses NetworkConfig or NetworkDesign
  - File: scripts/lib/validate_crds.sh — fixed to validate with kubectl apply --dry-run=server against pinned, committed CRDs/examples in deploy/ derived from the recorded upstream pins. Failure is no longer suppressed; the script exits on error.
    - Kubenet CRDs/examples: deploy/kubenet/crds/kubenet-crds.yaml and deploy/kubenet/topology.yaml
    - KUID CRDs: deploy/kuid/crds/kuid-crds.yaml
    - SDC CRDs: deploy/sdc/crds/sdc-crds.yaml
  - File: Makefile — target validate-crds runs the script and tees output to .wiggum/.../validate-crds.run.log; verify-compat depends on validate-crds.
  - Durable run log (successful server-side dry-run): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log
  - Kubenet API shape selection: versions.lock.yaml sets kubenet.api_shape: NetworkConfig
  - Proof slices:
    - scripts/lib/validate_crds.sh → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt
    - Makefile → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt (validate-crds and verify-compat targets)
    - Run log → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log
    - versions.lock.yaml → .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt (kubenet.api_shape: NetworkConfig)

Checkpoint: The compatibility manifest (versions.lock.yaml) is complete, immutable, and internally consistent. verify-pins enforces immutability and compatibility; preflight validates host/runtime; validate-crds provides server-side dry-run validation against the pinned API shape (NetworkConfig). All later manifests target this verified API shape.
