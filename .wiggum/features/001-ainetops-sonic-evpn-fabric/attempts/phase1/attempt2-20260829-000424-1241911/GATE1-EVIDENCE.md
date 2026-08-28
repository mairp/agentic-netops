# Phase 1 — Compatibility and repository foundation: Evidence

This evidence maps each task T001–T008 to concrete, independently readable files and line-numbered proof slices. Every cited path is relative to the workdir root.

Notes on grounding: For every criterion that names a file or symbol, we cite the exact file path and a line-numbered proof slice under gates/proofs.

## T001 Create the implementation directory structure from plan.md

Completed: The repository contains the lifecycle scripts, shared helpers, and Make wrappers exactly as enumerated in plan.md.

Cited files:
- plan.md (repository structure reference)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/plan.md.proof.txt
- scripts/provision.sh (sole provision entrypoint; invokes preflight and verify-compat)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt
- scripts/off.sh (sole teardown entrypoint)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.proof.txt
- Shared helpers in scripts/lib/: preflight.sh, verify_pins.sh, validate_crds.sh
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt
- Makefile (Make wrappers for verify-pins, validate-crds, verify-compat)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.verify-pins.proof.txt

## T002 Research and select one mutually compatible Kind binary/node image, Kubernetes, Kubenet/KUID, SDC, controller-runtime, and Go version set; record immutable releases/commits in versions.lock.yaml

Completed: versions.lock.yaml records immutable pins for Kind binary and node image digest, Kubernetes version, controller-runtime, Go, Kubenet release+commit, KUID release+commit, and SDC releases+commits.

Cited files:
- versions.lock.yaml (pins for Kind/Kubernetes/controller-runtime/Go/Kubenet/KUID/SDC)
  - Proof slice (lines 1–45): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.T002.proof.txt

## T003 Select and record a pinned containerlab version and both SONiC profile image digests; document artifact acquisition and redistribution constraints

Completed: versions.lock.yaml pins containerlab.version (semver) and both SONiC profiles with immutable sha256 digests, and documents redistribution constraints.

Cited files:
- versions.lock.yaml (containerlab.version + sonic_images.sonic_vs/.sonic_vm with digest; notes.redistribution)
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.T003.proof.txt

## T004 Select the SONiC/OpenConfig YANG schema commit and record its compatibility with each SONiC image profile

Completed: versions.lock.yaml pins sonic_yang.openconfig_commit and sonic_yang.sonic_native_commit and provides a compatibility matrix binding each pinned SONiC image (image@sha256) to oc_version/native_version commit prefixes.

Cited files:
- versions.lock.yaml (sonic_yang commits + compatibility entries for sonic_vs and sonic_vm)
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.T004.proof.txt

## T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, the Grafana Flow plugin, and topology-generation tooling images/charts

Completed: versions.lock.yaml tooling section pins all required images by immutable @sha256 digests, including grafana_flow_plugin and topology_generator.

Cited files:
- versions.lock.yaml (tooling: gnmic, otel_collector, prometheus, grafana, grafana_flow_plugin, topology_generator)
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.T005.proof.txt

## T006 Implement make verify-pins to reject latest, floating refs, missing digests, and inconsistent compatibility metadata (NFR-003)

Completed: The Makefile defines verify-pins and wires it to scripts/lib/verify_pins.sh. The verifier rejects:
- floating refs (latest/main/master/HEAD),
- missing digests (tooling and SONiC images),
- missing Kind node image digest,
- missing semver pins for controller-runtime and containerlab,
- missing 40-hex commits for Kubenet/KUID/SDC,
- missing sonic_yang openconfig_commit/sonic_native_commit, and
- inconsistency in YANG compatibility matrix relative to the pinned image digests and commit prefixes.

Cited files and symbols:
- Makefile target verify-pins
  - File: Makefile
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.verify-pins.proof.txt (shows verify-pins calling scripts/lib/verify_pins.sh)
- scripts/lib/verify_pins.sh (rejects latest/floating, enforces digests, validates compatibility)
  - File: scripts/lib/verify_pins.sh
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt (greppable symbols: "floating refs", "tooling images", "sonic_vs image and digest required", "compatibility missing")

## T007 Implement reusable strict-shell preflight for host resources, Kind/runtime privileges, address conflicts, tool versions, MTU, and KVM when required; invoke it from scripts/provision.sh (FR-002, FR-021, NFR-004)

Completed: scripts/lib/preflight.sh implements and scripts/provision.sh invokes preflight::run. The preflight provides:
- preflight::host_resources (CPU/RAM/disk),
- preflight::runtime_privileges (Docker daemon reachability),
- preflight::address_conflicts (CIDR overlap math between AINETOPS_MGMT_CIDR and pod/service CIDRs),
- preflight::mtu (warn if <1500),
- preflight::kvm_check (requires /dev/kvm for sonic-vm),
- preflight::tool_versions (compares host kind/kubectl/helm/containerlab to pins in versions.lock.yaml), and
- preflight::run that orchestrates the checks.

Cited files and symbols:
- scripts/lib/preflight.sh (functions preflight::address_conflicts, preflight::tool_versions, preflight::run)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
- scripts/provision.sh (sources preflight and invokes preflight::run; also runs verify-compat)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt

## T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document whether the selected release uses NetworkConfig or NetworkDesign

Completed: scripts/lib/validate_crds.sh extracts pinned Kubenet/KUID commits and SDC release from versions.lock.yaml and runs kubectl apply --dry-run=server with separate -f arguments per URL to avoid concatenation issues. The selected Kubenet api_shape is recorded as NetworkConfig in versions.lock.yaml.

Cited files and symbols:
- scripts/lib/validate_crds.sh (server-side dry-run using pinned refs; multiple -f flags)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt
- versions.lock.yaml (kubenet.api_shape: NetworkConfig)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.T002.proof.txt

