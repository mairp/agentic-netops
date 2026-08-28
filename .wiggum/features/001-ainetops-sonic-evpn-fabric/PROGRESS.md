done:
  - T001 Directory skeleton created per plan.md; scripts/provision.sh and scripts/off.sh added; shared script helpers in scripts/lib/; Makefile with verify-pins and validate-crds; versions.lock.yaml created.
  - T002 versions.lock.yaml records mutually compatible Kind binary/node image, Kubernetes, controller-runtime, and Go pins; Kubenet/KUID/SDC release+commit pins captured.
  - T003 containerlab.version pinned (semver) and both SONiC profile images include immutable sha256 digests; sonic_vm placeholder replaced with operator-built digest; redistribution constraints documented under notes.redistribution.
  - T004 sonic_yang.openconfig_commit and sonic_yang.sonic_native_commit pinned; compatibility matrix ties each SONiC image@sha256 to oc/native commit prefixes (updated to the sonic_vm digest).
  - T005 tooling images pinned by immutable digests: gnmic, otel_collector, prometheus, grafana, grafana_flow_plugin, topology_generator.
  - T006 Top-level Makefile present and wired verify-pins to scripts/lib/verify_pins.sh; verifier rejects floating refs, missing digests, and mismatched compatibility.
  - T007 Preflight strengthened: address-overlap math, tool version checks against versions.lock.yaml, MTU, KVM; invoked from scripts/provision.sh.
  - T008 validate_crds.sh now validates with kubectl --dry-run=server against committed local CRDs/examples in deploy/ derived from the pinned commits; failures are not suppressed; durable run log added.
verified:
  - Proof slices added for versions.lock.yaml (T002–T005), Makefile targets verify-pins/validate-crds, scripts/lib/verify_pins.sh, scripts/lib/preflight.sh, scripts/lib/validate_crds.sh, scripts/provision.sh, and the validate-crds run log.

blocked:
  - none
next:
  - Proceed to Phase 2 once Gate 1 is approved.

# Phase 3 progress

done:
  - T018 Kind cluster foundation: config/kind/cluster.yaml authored with stable name, pinned node image, non-overlapping pod/service CIDRs, extra ports/mounts; scripts/lib/kind.sh implements idempotent ensure/delete, kube-context verification, node-image verification, and partial-failure recovery.
  - T019 Dedicated Docker management network created/labeled and reused by containerlab; Kind nodes attached idempotently; separation and in-cluster gNMI reachability proven.
  - T020 Pinned Kubenet/KUID CRDs/controllers installed in Kind and basic readiness waited.
  - T021 Pinned SDC CRDs and schema/config/data/cache components with PVCs installed and waited to Ready.
  - T022 Namespaces, service accounts, RBAC, NetworkPolicies, and lab credential/TLS Secrets created via Kubernetes; generator Job populates Secrets (no credentials in Git).
  - T023 Authored AINETOPS provider and SRv6 controller Helm values and manifest excerpts; FR-023 prohibition documented.
  - T024 SONiC Schema, connection profile, sync profile, and address-based DiscoveryRule created; four SDC Target resources observed.
  - T025 Topology, indices, claims/pools, and SRv6 pools created using Kubenet/KUID; negative tests recorded for missing Secret, schema mismatch, unreachable target, and exhausted claim.

verified:
  - Proof slices and kubectl outputs staged under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/, including negative-case status/Event outputs.

blocked:
  - none

next:
  - Proceed to Phase 4 once Gate 3 is approved.

