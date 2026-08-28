# Phase 1 — Compatibility and repository foundation: Evidence (Attempt 2)

This evidence addresses every required task in Phase 1, with concrete file paths and proof slices suitable for the grounding snapshot. Where an acceptance criterion names a file or symbol, we cite it and stage a line-numbered proof excerpt under gates/proofs/.

## T001 Create the implementation directory structure from plan.md

- Implemented directories and lifecycle scripts:
  - scripts/provision.sh
  - scripts/off.sh
  - scripts/lib/preflight.sh
  - scripts/lib/verify_pins.sh
  - scripts/lib/validate_crds.sh
  - Makefile (top-level)
  - versions.lock.yaml
- Proof slices:
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.proof.txt (lines show provision script scaffold and library sourcing)
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.off.sh.proof.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.preflight.sh.proof.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.verify_pins.sh.proof.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.validate_crds.sh.proof.txt
  - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.proof.txt

## T002 Research and select compatible Kind/Kubernetes/Kubenet/KUID/SDC/controller-runtime/Go; record immutable versions in versions.lock.yaml

- Recorded immutable selections in versions.lock.yaml, including Kind binary, node image with digest, Kubernetes version, controller-runtime, and Go:
  - File: versions.lock.yaml
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/versions.lock.yaml.proof.txt (see lines 5–13 for kind/kubernetes/controller_runtime/go pins)

## T003 Pin containerlab and SONiC profile images; document acquisition/redistribution constraints

- Pinned containerlab version and both SONiC profiles with image and digest; added redistribution notes:
  - File: versions.lock.yaml (sections containerlab and sonic_images)
  - Proof: .wiggum/.../proofs/versions.lock.yaml.proof.txt (see lines 27–39 for containerlab, 30–38 for SONiC images)

## T004 Select SONiC/OpenConfig YANG schema commit and record compatibility per SONiC image profile

- Recorded exact commits and compatibility mapping for each image (image URL with digest plus oc/native commit prefixes):
  - File: versions.lock.yaml (section sonic_yang)
  - Proof: .wiggum/.../proofs/versions.lock.yaml.proof.txt (see lines 40–49 for commits and mapping)

## T005 Pin gNMIc, OTel Collector, Prometheus, Grafana, Grafana Flow plugin, topology-generation tooling

- Pinned all tooling images by immutable digests:
  - File: versions.lock.yaml (section tooling)
  - Proof: .wiggum/.../proofs/versions.lock.yaml.proof.txt (see lines 51–57)

## T006 Implement make verify-pins to reject latest/floating refs/missing digests/inconsistent compatibility (NFR-003)

- Implemented scripts/lib/verify_pins.sh and Makefile target verify-pins. The script rejects floating refs, enforces digests, semver, 40-hex commits, and verifies the sonic_yang compatibility matrix against the selected image+digest set and commit prefixes.
  - Files:
    - scripts/lib/verify_pins.sh
    - Makefile (target verify-pins)
  - Proof:
    - .wiggum/.../proofs/scripts.lib.verify_pins.sh.proof.txt (lines 13–16 reject latest/main/master/HEAD; lines 28–35 check digests/versions; lines 37–45 enforce release/commit/api_shape; lines 47–52 enforce tooling/containerlab; lines 53–66 require SONiC digests; lines 67–85 validate sonic_yang compatibility against commit prefixes)
    - .wiggum/.../proofs/Makefile.proof.txt (lines 11–13 define verify-pins target invoking the script)

## T007 Implement reusable strict-shell preflight and invoke from scripts/provision.sh (FR-002, FR-021, NFR-004)

- Implemented scripts/lib/preflight.sh performing host resource checks, runtime privileges, MTU, KVM where required, versions.lock.yaml floating-ref rejection, and required tool presence.
- Invoked from scripts/provision.sh before verification targets.
  - Files:
    - scripts/lib/preflight.sh
    - scripts/provision.sh
  - Proof:
    - .wiggum/.../proofs/scripts.lib.preflight.sh.proof.txt (lines 12–20 check versions.lock.yaml and floating refs; lines 22–35 host resource checks; lines 37–43 runtime privileges; lines 52–57 MTU; lines 59–65 KVM; lines 67–71 tool presence; lines 72–81 run aggregator)
    - .wiggum/.../proofs/scripts.provision.sh.proof.txt (lines 11–16 source and run preflight)

## T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document API shape

- Implemented validate-crds automation and integrated it into provisioning so validation is executed as part of Phase 1 gate. The automation uses the pinned refs from versions.lock.yaml and performs kubectl apply --dry-run=server on:
  - Kubenet CRDs (networks, networkdevices)
  - KUID CRDs (claims)
  - SDC CRDs (schemas, configs, targets)
  - One Kubenet example manifest consistent with the pinned API shape.
- Evidence of execution is captured to a durable log file.
  - Files:
    - scripts/lib/validate_crds.sh
    - Makefile targets: validate-crds and verify-compat
    - scripts/provision.sh now invokes make verify-compat to run both pin verification and CRD validation
    - versions.lock.yaml retains kubenet.api_shape: NetworkConfig
  - Proof:
    - .wiggum/.../proofs/scripts.lib.validate_crds.sh.proof.txt (entire script; lines 53–61 show CRD and example dry-run invocations; lines 17–23 extract pinned refs; lines 26–41 enumerate exact upstream paths)
    - .wiggum/.../proofs/Makefile.proof.txt (lines 17–23 define validate-crds and verify-compat; tee path to proofs/validate-crds.run.log)
    - .wiggum/.../proofs/scripts.provision.sh.proof.txt (lines 18–23 show verify-compat invoked from provision)
    - .wiggum/.../proofs/validate-crds.run.log (captured run output including each server-side dry-run and final OK)
    - .wiggum/.../proofs/versions.lock.yaml.proof.txt (lines 14–18 show kubenet.api_shape: NetworkConfig)

---

All evidence is grounded to the cited files. No floating refs or latest tags remain; the compatibility manifest is complete, immutable, and internally consistent for Phase 1.
