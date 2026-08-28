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
