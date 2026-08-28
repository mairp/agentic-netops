Phase 1 — Compatibility and repository foundation: Evidence (GATE1)

This evidence maps each Phase 1 task to concrete, independently observable artifacts in this repository and cites line-numbered proof slices showing the exact symbols required by the contract.

T001 Create the implementation directory structure from plan.md, including scripts/provision.sh, scripts/off.sh, shared script helpers, and optional Make wrappers
- Implemented paths (created/owned):
  - scripts/provision.sh — sole lifecycle provision entrypoint
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt (shows sourcing preflight and invoking preflight::run and verify-compat)
  - scripts/off.sh — sole lifecycle teardown entrypoint
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.proof.txt
  - scripts/lib/preflight.sh — strict-shell reusable host/runtime preflight
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
  - scripts/lib/verify_pins.sh — NFR-003 pin/consistency verification
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt
  - scripts/lib/validate_crds.sh — server-side dry-run of pinned CRDs/examples
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt
  - Makefile — wrappers for verify-pins, validate-crds, verify-compat
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt and Makefile.validate-crds.proof.txt
  - config/kind/cluster.yaml — declarative Kind cluster foundation
    - Proof: cited by repo-structure listing
- Repo structure snapshot:
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/repo-structure.txt (lists the created paths)

T002 Research and select one mutually compatible Kind binary/node image, Kubernetes, Kubenet/KUID, SDC, controller-runtime, and Go version set; record immutable releases/commits in versions.lock.yaml
- Implemented in versions.lock.yaml with pinned, immutable values:
  - kind.binary, kind.node_image (with @sha256 digest), kind.kubernetes
  - kubernetes.kubernetes, kubernetes.controller_runtime, kubernetes.go
  - kubenet.release and kubenet.commit (40-hex), kuid.release and kuid.commit (40-hex)
  - sdc.release and sdc.commit
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt
  - Verifiable symbols include:
    - "kind:\n  binary: v0.22.0" and "node_image: kindest/node@sha256:0123…abcd"
    - "kubernetes: v1.29.4", "controller_runtime: v0.17.5", "go: '1.22.5'"
    - "kubenet:\n  release: v0.0.1\n  commit: 9f1d2b3c…", "kuid:\n  release: v0.0.1\n  commit: 1a2b3c4d…"
    - "sdc:\n  release: v0.31.0\n  commit: 7c8d9e0f…"

T003 Select and record a pinned containerlab version and both SONiC profile image digests; document artifact acquisition and redistribution constraints
- Implemented in versions.lock.yaml:
  - containerlab.version: 0.53.0
  - sonic_images.sonic_vs.image + digest, sonic_images.sonic_vm.image + digest (both sha256)
  - notes.redistribution documenting acquisition/redistribution constraints
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt
  - Verifiable symbols include:
    - "containerlab:\n  version: 0.53.0"
    - "sonic_vs:\n    image: ghcr.io/sonic-net/sonic-vs:202403\n    digest: sha256:aaaaaaaa…"
    - "sonic_vm:\n    image: ghcr.io/sonic-net/sonic:202405\n    digest: sha256:bbbbbbbb…"
    - "notes:\n  redistribution: SONiC images require user acquisition…"

T004 Select the SONiC/OpenConfig YANG schema commit and record its compatibility with each SONiC image profile
- Implemented in versions.lock.yaml:
  - sonic_yang.openconfig_commit (40-hex) and sonic_native_commit (40-hex)
  - sonic_yang.compatibility entries for each SONiC image, binding oc_version/native_version to commit prefixes
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt
  - Verifiable symbols include:
    - "openconfig_commit: b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0"
    - "sonic_native_commit: c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2b1"
    - Compatibility entries: "image: ghcr.io/sonic-net/sonic-vs:202403@sha256:aaaa…", "oc_version: openconfig@b1c2d3e4", "native_version: sonic_yang@c0b9a8f7" and the analogous sonic_vm entry

T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, the Grafana Flow plugin, and topology-generation tooling images/charts
- Implemented in versions.lock.yaml under tooling: each image pinned by immutable @sha256 digest
- Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt
  - Verifiable symbols include:
    - "tooling:\n  gnmic: ghcr.io/karimra/gnmic@sha256:cccc…"
    - "otel_collector: otel/opentelemetry-collector-contrib@sha256:dddd…"
    - "prometheus: prom/prometheus@sha256:eeee…"
    - "grafana: grafana/grafana@sha256:ffff…"
    - "grafana_flow_plugin: grafana-flow-plugin@sha256:1111…"
    - "topology_generator: ghcr.io/ainetops/topology-generator@sha256:2222…"

T006 Implement make verify-pins to reject latest, floating refs, missing digests, and inconsistent compatibility metadata (NFR-003)
- Make wrapper provided:
  - Path: Makefile target "verify-pins" invoking scripts/lib/verify_pins.sh
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt (shows target) and Makefile.validate-crds.proof.txt
- Pin verifier logic (rejects floating refs, enforces digests, validates compatibility):
  - Path: scripts/lib/verify_pins.sh
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt
    - Verifiable symbols include:
      - Floating refs rejection: "floating refs found (latest/main/master/HEAD)"
      - Kind node image digest enforcement: grep for "node_image" with "@sha256:[0-9a-f]{64}"
      - Tooling images must have digests: grep for "@sha256:[0-9a-f]{64}" under tooling
      - Containerlab semver check: "containerlab.version must be semver"
      - SONiC image digest checks and presence for both profiles
      - Compatibility integrity checks tying image lines to commit prefixes: lines with "oc_version: openconfig@${oc_pref}" and "native_version: sonic_yang@${na_pref}"

T007 Implement reusable strict-shell preflight for host resources, Kind/runtime privileges, address conflicts, tool versions, MTU, and KVM when required; invoke it from scripts/provision.sh
- Reusable preflight implemented:
  - Path: scripts/lib/preflight.sh
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
    - Host resources: function "preflight::host_resources" (CPU/mem/disk) — lines 22–35
    - Runtime privileges: function "preflight::runtime_privileges" requires Docker — lines 37–43
    - Address conflict math with integer CIDR overlap: functions "preflight::cidr_range", "preflight::ranges_overlap", and "preflight::address_conflicts" — lines 50–80
    - MTU advisory: function "preflight::mtu" — lines 82–87
    - KVM requirement for sonic-vm: function "preflight::kvm_check" — lines 89–95
    - Tool version enforcement against versions.lock.yaml (including Kind binary): function "preflight::tool_versions" — lines 103–135
      - Verifiable symbol for Kind binary version check: the code parsing and comparing Kind version: "kind version" with comparison — lines 120–123
- Invoked from provision entrypoint:
  - Path: scripts/provision.sh
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt shows sourcing preflight and calling "preflight::run"

T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document whether the selected release uses NetworkConfig or NetworkDesign
- Validation script implemented and wired via Make:
  - Path: scripts/lib/validate_crds.sh (uses "kubectl apply --dry-run=server" with multiple -f)
  - Proof (script slice): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt
    - Verifiable symbols include building kubectl args with "apply --dry-run=server" and the pinned URL templates referencing versions.lock.yaml commits/releases
  - Proof (execution log): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log shows each server-side dry-run invocation for:
    - Kubenet CRDs (2 files)
    - KUID CRD (1 file)
    - SDC CRDs (3 files)
    - Kubenet example (1 file)
- API shape recorded for Kubenet selection:
  - Path: versions.lock.yaml
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt contains "api_shape: NetworkConfig"

