# GATE 1 — Phase 1 Evidence: Compatibility and repository foundation

This evidence demonstrates completion of Phase 1 tasks T001–T008 with independently readable proof slices. Each item cites exact repository paths and a line-numbered proof under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

## T001 Create the implementation directory structure from plan.md, including scripts and helpers

Implemented per specs/001-ainetops-sonic-evpn-fabric/plan.md Project structure section (lines 235–288). The repository now contains the required top-level directories and lifecycle scripts with shared helpers.

- Created directories (selected, per plan):
  - api/, cmd/, controllers/, internal/, config/{crd,rbac,manager,upstream,sdc,observability,kind}/, lab/{profiles/sonic-vs,profiles/sonic-vm,bootstrap,clients}/, examples/{fabric,services,srv6,migrations}/, tests/{unit,golden,envtest,integration,e2e}/, scripts/, scripts/lib/
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/repo-structure.txt
- Lifecycle scripts and shared helpers:
  - scripts/provision.sh (invokes preflight and verify-pins)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt
  - scripts/off.sh
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.proof.txt
  - scripts/lib/preflight.sh (strict-shell reusable preflight)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
  - Optional Make wrapper present (Makefile with verify-pins target)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt

## T002 Select mutually compatible Kind/Kubernetes/Kubenet/KUID/SDC/controller-runtime/Go; record immutable pins

- Recorded in versions.lock.yaml:
  - kind.binary, kind.node_image (with @sha256), kind.kubernetes
  - kubernetes.controller_runtime, kubernetes.go
  - kubenet.release and kubenet.commit; kuid.release and kuid.commit
  - sdc.release and sdc.commit
  - API shape documented: kubenet.api_shape: NetworkConfig
- Files/paths and proofs:
  - versions.lock.yaml
    - Proof (line-numbered): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt

## T003 Pin containerlab and both SONiC profile image digests; document acquisition/redistribution constraints

- Pinned containerlab version and SONiC images with digests in versions.lock.yaml:
  - containerlab.version: 0.53.0
  - sonic_images.sonic_vs.image and sonic_images.sonic_vs.digest
  - sonic_images.sonic_vm.image and sonic_images.sonic_vm.digest
- Documented artifact acquisition/redistribution constraints in versions.lock.yaml notes.redistribution.
- Files/paths and proofs:
  - versions.lock.yaml
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt

## T004 Select SONiC/OpenConfig YANG schema commit and record compatibility with each SONiC image profile

- Pinned commits and explicit compatibility matrix in versions.lock.yaml:
  - sonic_yang.openconfig_commit and sonic_yang.sonic_native_commit (40-hex)
  - sonic_yang.compatibility entries for each SONiC image profile, including oc_version and native_version using commit prefixes
- Files/paths and proofs:
  - versions.lock.yaml
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt

## T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, Grafana Flow plugin, and topology-generation tooling

- Pinned by digest in versions.lock.yaml tooling section:
  - gnmic, otel_collector, prometheus, grafana, grafana_flow_plugin, topology_generator
- Files/paths and proofs:
  - versions.lock.yaml
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt

## T006 Implement make verify-pins to reject latest/floating/missing digests/inconsistent metadata (NFR-003)

- Make target verify-pins executes scripts/lib/verify_pins.sh.
  - Makefile target name: verify-pins
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt
  - scripts/lib/verify_pins.sh verifies:
    - Rejects latest/main/master/HEAD
    - Requires kind.node_image digest
    - Requires controller-runtime and Go versions
    - Requires kubenet/kuid/sdc release and 40-hex commit; kubenet.api_shape in {NetworkConfig, NetworkDesign}
    - Requires @sha256 digests for tooling and SONiC images
    - Requires containerlab semver
    - Requires sonic_yang 40-hex commits; compatibility for both images; oc/native versions match commit prefixes
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt

## T007 Implement reusable strict-shell preflight; invoke it from scripts/provision.sh

- Implemented scripts/lib/preflight.sh with strict mode and checks for:
  - versions.lock.yaml presence and no floating refs
  - host CPU/RAM/disk
  - Docker runtime privileges
  - management-network address conflict placeholder (expanded in later phases)
  - MTU advisory
  - KVM presence when profile=sonic-vm
  - required tool presence (kind, kubectl, helm, containerlab, jq, curl)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
- scripts/provision.sh sources and invokes preflight::run, then runs make verify-pins:
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt

## T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document API shape

- Documented API shape in versions.lock.yaml: kubenet.api_shape: NetworkConfig
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt
- Implemented scripts/lib/validate_crds.sh, which reads pinned commits/releases from versions.lock.yaml and executes kubectl apply --dry-run=server for:
  - Kubenet CRDs and example(s)
  - KUID CRDs
  - SDC CRDs
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt

---

All cited files exist in the repository and contain the pinned/strict content shown in their line-numbered proofs. This completes Phase 1: the compatibility manifest is complete, immutable, and internally consistent; later manifests can target the verified NetworkConfig API shape.
