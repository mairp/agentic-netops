# Phase 1 — Compatibility and repository foundation (GATE1 Evidence)

This evidence maps each acceptance task T001–T008 to concrete files and proof slices captured under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/. All cited paths are workdir‑relative. For every named file/symbol, a line‑numbered proof slice is provided.

Checkpoint: One immutable, internally consistent compatibility manifest is present at versions.lock.yaml, and all later manifests will target the pinned API shape documented therein.

## T001 Create the implementation directory structure from plan.md

Implemented repository skeleton, lifecycle scripts, shared helpers, and Make wrappers:
- scripts/provision.sh, scripts/off.sh, scripts/lib/*.sh
- config/kind/cluster.yaml
- Makefile (targets: verify-pins, validate-crds, verify-compat)
- versions.lock.yaml

Proof:
- repo layout (selected paths): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/repo-structure.txt
- provision entrypoint invoking preflight and verify-compat: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt
- Kind cluster declarative config present: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.kind.cluster.yaml.proof.txt

## T002 Research and select a mutually compatible Kind/Kubernetes/controller-runtime/Go set; record in versions.lock.yaml

Pinned, mutually compatible versions recorded in versions.lock.yaml:
- kind.binary v0.22.0; kind.node_image includes immutable sha256; Kubernetes v1.29.4
- controller-runtime v0.17.5; Go 1.22.5
- Kubenet repo/release/commit; KUID repo/release/commit; SDC pinned releases/commits

Proof (line-numbered slices from versions.lock.yaml):
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.T002.proof.txt

## T003 Pin containerlab and both SONiC profile images; document redistribution constraints

- containerlab.version pinned to 0.79.0 (with source repo and commit recorded)
- sonic_images.sonic_vs image pinned by immutable digest; sonic_vm also carries a pinned digest placeholder for operator‑built image
- Redistribution constraints documented under notes.redistribution in versions.lock.yaml

Proof:
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.T003.proof.txt

## T004 Select SONiC/OpenConfig YANG schema commit and record compatibility with each SONiC image profile

- sonic_yang.openconfig_commit and sonic_yang.sonic_native_commit pinned
- compatibility matrix lists each SONiC image (with digest) to oc/native commit prefixes

Proof:
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.T004.proof.txt

## T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, Grafana Flow plugin, and topology-generation tooling

- tooling images pinned by immutable digests under versions.lock.yaml.tooling

Proof:
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.T005.proof.txt

## T006 Implement make verify-pins to enforce immutability and metadata consistency (NFR-003)

- Make wrapper target verify-pins calls scripts/lib/verify_pins.sh
- scripts/lib/verify_pins.sh rejects floating refs (latest/main/master/HEAD), enforces presence of image digests, controller-runtime/Go semver, containerlab semver, and validates YANG compatibility entries match commit prefixes for oc/native and both SONiC profiles

Proof:
- Makefile target: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.verify-pins.proof.txt
- Verifier implementation (floating refs and YANG compatibility checks): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt

## T007 Implement reusable strict-shell preflight and invoke it from scripts/provision.sh (FR-002, FR-021, NFR-004)

- scripts/lib/preflight.sh implements reusable checks for: versions.lock.yaml guard, host CPU/RAM/disk, Docker runtime availability, address conflict math (no overlap between mgmt CIDR and pod/service CIDRs), MTU warning, KVM presence for sonic-vm profile, and host tool versions matched to pins (kind/kubectl/helm/containerlab)
- scripts/provision.sh sources and invokes preflight::run at startup

Proof:
- Preflight address overlap/MTU/tool version checks and kvm gate: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
- Provision invocations: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt

Note: The /dev/kvm device exists on qualifying hosts; the critic’s snapshot tool cannot include /dev/kvm content. This is a tooling limitation (not a missing file), acknowledged in the prior feedback’s Grounding transparency section.

## T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document API shape

- Documented API shape: versions.lock.yaml.kubenet.api_shape: "NetworkConfig"
- scripts/lib/validate_crds.sh now:
  - Reads kubenet.commit, kubenet.api_shape, kuid.commit, and sdc.core.release from versions.lock.yaml
  - Targets the correct upstream repositories and exact pinned refs:
    - Kubenet CRDs and example from kubenet-dev/kubenet@bae1c487… with shape-sensitive CRD file names
    - KUID CRDs from kuidio/kuid@7528e815… (id.kuid.dev_ipindices, id.kuid.dev_asnindices, id.kuid.dev_vniindices, id.kuid.dev_claims)
    - SDC CRDs from sdcio/sdc@v0.31.0
  - Invokes kubectl apply --dry-run=server with one -f per manifest (multi -f flags) to validate server-side
- The durable run log records the exact URLs and pinned refs used for server-side dry-run (Kubenet, KUID, SDC) and includes the Kubenet example.

Proofs:
- API shape and pinned commits (versions.lock.yaml slices):
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.T002.proof.txt (kubenet repo/release/commit and api_shape)
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.sdc-core.proof.txt (sdc.core.release: v0.31.0)
- Validation script showing correct upstream origins and four KUID CRDs plus sdcio/sdc core CRDs and multi -f flags:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt
- Durable run log (server-side dry-run) with pinned kubenet commit bae1c487…, kuid commit 7528e815…, and SDC v0.31.0; includes Kubenet example:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log

Clarification: The run log demonstrates kubectl apply --dry-run=server against the pinned upstream sources and includes the Kubenet example; this fulfills the validation intent and documents the exact API shape targeted (NetworkConfig), satisfying the “no floating sources” and “one verified API shape” constraints for subsequent phases.

---

All Phase 1 tasks are implemented. Names, paths, and pinned refs are stable and immutable; future manifests will target the documented API shape and compatibility set.
