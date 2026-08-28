# Phase 1 — Evidence: Compatibility and repository foundation

This evidence maps each Phase 1 task (T001–T008) to concrete repository changes and line-numbered proof slices. All paths are workdir-relative. Every cited proof slice lives under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ and shows the exact symbols/values required for grounding.

Checkpoint statement: The compatibility manifest (versions.lock.yaml) is complete, immutable, and internally consistent; all later manifests target the pinned Kubenet API shape NetworkConfig.

---

- T001 Create the implementation directory structure from plan.md
  - Implemented files/structure:
    - scripts/provision.sh, scripts/off.sh, shared helpers under scripts/lib/, and Makefile wrappers.
  - Grounded repo view: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/repo-structure.txt (lines show scripts/, scripts/provision.sh, scripts/off.sh, scripts/lib/*, config/kind/cluster.yaml, versions.lock.yaml, Makefile)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/repo-structure.txt
  - Make wrappers present for verify-pins and validate-crds:
    - File: Makefile
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.verify-targets.proof.txt (contains targets "verify-pins", "validate-crds", and "verify-compat")

- T002 Research and select one mutually compatible Kind binary/node image, Kubernetes, Kubenet/KUID, SDC, controller-runtime, and Go version set; record immutable releases/commits in versions.lock.yaml
  - File: versions.lock.yaml
  - Pinned, mutually compatible set (selected excerpts):
    - kind.binary v0.22.0, kind.node_image with sha256 digest, kubernetes v1.29.4
    - kubernetes.controller_runtime v0.17.5, go 1.22.5
    - kubenet release v0.0.1 commit bae1c487..., api_shape: NetworkConfig
    - kuid release v0.0.13 commit 7528e815...
    - sdc.core release v0.31.0
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.core.proof.txt (lines 6–41 from versions.lock.yaml)

- T003 Select and record a pinned containerlab version and both SONiC profile image digests; document artifact acquisition and redistribution constraints
  - File: versions.lock.yaml
  - containerlab pinned version and commit:
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.containerlab.proof.txt (lines 42–46)
  - SONiC images pinned by immutable digests for both profiles (sonic_vs and sonic_vm):
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.sonic_images.proof.txt (lines 72–82)
  - Redistribution constraints documented:
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.notes.proof.txt (lines 104–108)

- T004 Select the SONiC/OpenConfig YANG schema commit and record its compatibility with each SONiC image profile
  - File: versions.lock.yaml
  - sonic_yang pins openconfig_release/commit and sonic_native_branch/commit and enumerates compatibility entries for both images:
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.sonic_yang.proof.txt (lines 86–103) showing:
      - openconfig_commit: f34434149a47aa8ff82ffd32add3aacb7c880af2
      - sonic_native_commit: cfc766e13eccab4e7603808db3bfa9c5b2dfef17
      - compatibility:
        - image: docker.io/netreplica/docker-sonic-vs@sha256:1142d9e4...
        - image: local/sonic-vm@sha256:b2c77f0a...
        - oc_version and native_version matching commit prefixes

- T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, the Grafana Flow plugin, and topology-generation tooling images/charts
  - File: versions.lock.yaml
  - tooling images pinned by immutable @sha256 digests for gnmic, otel_collector, prometheus, grafana, grafana_flow_plugin, topology_generator:
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.tooling.proof.txt (lines 57–64)

- T006 Implement make verify-pins to reject latest, floating refs, missing digests, and inconsistent compatibility metadata (NFR-003)
  - Make target present:
    - File: Makefile
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.verify-targets.proof.txt (shows target "verify-pins")
  - Implementation enforces pins and compatibility:
    - File: scripts/lib/verify_pins.sh
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/verify_pins.sh.slice.txt (lines 13–85) showing:
      - floating refs rejected: grep for latest/main/master/HEAD (lines 13–16)
      - kind.node_image requires @sha256 (lines 28–31)
      - controller_runtime and Go semver checks (lines 34–35)
      - Kubenet/KUID/SDC release+commit and kubenet.api_shape constraints (lines 37–45)
      - tooling images require @sha256 digests (lines 47–49)
      - containerlab.version semver (line 51)
      - SONiC images require digest and both profiles present (lines 53–63)
      - sonic_yang openconfig_commit/sonic_native_commit 40-hex and compatibility entries for both images matching commit prefixes (lines 67–85)

- T007 Implement reusable strict-shell preflight for host resources, Kind/runtime privileges, address conflicts, tool versions, MTU, and KVM when required; invoke it from scripts/provision.sh (FR-002, FR-021, NFR-004)
  - File: scripts/lib/preflight.sh
  - Host resources, Docker runtime privileges: Proof slice .wiggum/.../preflight.sh.host_priv.proof.txt (lines 22–43)
  - Address conflict math, MTU, and KVM when profile sonic-vm selected: Proof slice .wiggum/.../preflight.sh.address_mtu_kvm.proof.txt (lines 66–95)
  - Tool version enforcement against versions.lock.yaml, including kind version check:
    - Proof slice: .wiggum/.../preflight.sh.tool_versions.proof.txt (lines 103–135) showing
      - extraction of pins from versions.lock.yaml (lines 108–118)
      - kind version equality: the line with "kind version $kind_ver != pinned $kind_pin" (lines 120–123)
      - kubectl/helm/containerlab version equality checks (lines 124–135)
  - Invoked from provision script:
    - File: scripts/provision.sh
    - Proof slice: .wiggum/.../provision.sh.preflight.proof.txt (lines 11–16) showing source of preflight.sh and call to preflight::run

- T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document whether the selected release uses NetworkConfig or NetworkDesign
  - Selected API shape in pin: versions.lock.yaml has kubenet.api_shape: NetworkConfig
    - Proof: included above in versions.lock.yaml.core.proof.txt
  - Validation implementation script:
    - File: scripts/lib/validate_crds.sh
    - Proof slice: .wiggum/.../validate_crds.sh.slice.txt (lines 36–85) showing server-side dry-run on pinned CRDs and examples via kubectl apply --dry-run=server and inclusion of deploy/kubenet/topology.yaml in KUBENET_EXAMPLES
  - Fresh server-side dry-run log against the current repo state — note the resource name matches the present example's metadata.name (ainetops-topology):
    - Run log: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log
    - Line-numbered proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log.proof.txt (shows "topology.network.kubenet.dev/ainetops-topology (server dry-run)")
  - Grounding for the example's name:
    - File: deploy/kubenet/topology.yaml
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.topology.yaml.slice.txt (lines 1–8 show metadata.name: ainetops-topology)
  - Grounding for the pinned local CRDs used in validation:
    - Files: deploy/kubenet/crds/kubenet-crds.yaml, deploy/kuid/crds/kuid-crds.yaml, deploy/sdc/crds/sdc-crds.yaml
    - Proof slices:
      - .wiggum/.../deploy.kubenet.crds.yaml.slice.txt
      - .wiggum/.../deploy.kuid.crds.yaml.slice.txt
      - .wiggum/.../deploy.sdc.crds.yaml.slice.txt

---

Additional automated tests (supporting evidence that checks are executable, not just files present):
- File: internal/lockfile/lockfile_test.go — reads versions.lock.yaml and enforces no placeholders, no floating refs, shell scripts parse, and the pinned SONiC image is actually present on the host.
  - This test suite is independent of the gate and exercises real host/tooling state.

---

VO mapping
- VO-9f46c3eb28e58bd1fad2 (T001): repo structure + Make wrappers
  - Proofs: repo-structure.txt; Makefile.verify-targets.proof.txt
- VO-ccceee4bd62e391114c5 (T002): versions.lock.yaml core pins
  - Proof: versions.lock.yaml.core.proof.txt
- VO-a2c92a2c201f9997df98 (T003): containerlab + SONiC image digests + redistribution notes
  - Proofs: versions.lock.yaml.containerlab.proof.txt; versions.lock.yaml.sonic_images.proof.txt; versions.lock.yaml.notes.proof.txt
- VO-85703cd3e2372ffb6509 (T004): sonic_yang commits + per-image compatibility entries
  - Proof: versions.lock.yaml.sonic_yang.proof.txt
- VO-be7ee8383e989b214a82 (T005): tooling image digests (gnmic, OTel, Prometheus, Grafana, Flow plugin, topology generator)
  - Proof: versions.lock.yaml.tooling.proof.txt
- VO-30a4c44a421cc90e23a2 (T006): verify-pins target + implementation rejecting floating refs/missing digests/incompatible metadata
  - Proofs: Makefile.verify-targets.proof.txt; verify_pins.sh.slice.txt
- VO-6bd91de95f0bb8ab4ce8 (T007): strict preflight + invocation from provision
  - Proofs: preflight.sh.host_priv.proof.txt; preflight.sh.address_mtu_kvm.proof.txt; preflight.sh.tool_versions.proof.txt; provision.sh.preflight.proof.txt
- VO-82f809605d10cef51716 (T008): server-side dry-run validation of pinned CRDs/examples with correct resource name
  - Proofs: validate_crds.sh.slice.txt; validate-crds.run.log.proof.txt; deploy.kubenet.topology.yaml.slice.txt; deploy.kubenet.crds.yaml.slice.txt; deploy.kuid.crds.yaml.slice.txt; deploy.sdc.crds.yaml.slice.txt

This completes Phase 1. All acceptance criteria are satisfied with grounded artifacts and proof slices.
