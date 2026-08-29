# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

Unmet or unclear acceptance criteria and concrete gaps:

- T029: Compatibility-set validation not integrated
  - Missing: No controller logic uses pkg/compat to validate image/schema/mapping/upstream API versions, no SAI SRv6 capability check, and no enforcement of pinned telemetry/topology label contracts.
  - Action: Wire compat.FromAnnotations/ValidatePins/FullValidate into reconcilers; set current-generation conditions with stable reasons (e.g., SchemaMismatch/CapabilityMissing) and gate downstream mutations when mismatched. Add unit/envtest coverage.

- T029a: Per-path OpenConfig-vs-SONiC register and CI guard incomplete
  - Missing: The register file exists (pkg/register/oc_vs_sonic.yaml) but is not complete “per-path for all rendered YANG paths,” and there is no CI/test that asserts new/changed rendered paths are registered and prefer OpenConfig.
  - Action: Implement renderer path enumeration and a test/linter that fails when a rendered YANG path lacks a register entry or regresses preference; expand the register to cover all rendered paths with justifications for any SONiC-native gaps.

- T031: Interface/loopback/MTU and dual-stack IPv4 /31 + IPv6 underlay renderers absent
  - Missing: No renderer code producing SDC Config for interfaces/loopbacks/MTU, IPv4 /31, and IPv6 underlay.
  - Action: Add renderer package (e.g., pkg/render/interfaces.go) with deterministic output and tests (golden/envtest).

- T032: BGP global/neighbor and EVPN AF renderers absent
  - Missing: No code to render BGP global, neighbors, and EVPN AF.
  - Action: Implement renderers and tests with deterministic output.

- T033: VLAN, bridge, VXLAN NVO, VTEP, and L2VNI renderers absent
  - Missing: No code rendering these L2 constructs.
  - Action: Implement renderers and golden/idempotence tests.

- T034: VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, egress End.DT46 renderers absent
  - Missing: No renderers for these L3/SRv6 constructs.
  - Action: Implement renderers and tests validating required behaviors.

- T035: Deterministic composition, stable names, canonical hashes, annotations, owner references absent
  - Missing: No composer to order output, generate stable names/hashes, attach compatibility annotations, or set owner refs to NetworkDevice/SRv6Service.
  - Action: Add composition layer with hashing and annotations; include tests proving determinism and stable naming.

- T036: Offline SDC/schema validation integration absent
  - Missing: No integration to validate rendered output against pinned schemas before apply, nor logic to emit no changed Config on validation failure.
  - Action: Integrate SDC offline validation (or equivalent) and enforce the “no-change on validation failure” contract; add tests for negative cases.

- T037: Server-side apply with dedicated field manager and explicit policies absent
  - Missing: No SSA usage, field manager name, or priority/operation/revertive/deletion policy handling.
  - Action: Use server-side apply (Apply/ApplyOptions.FieldManager) for SDC specs with explicit policy; add tests for ownership and deletion semantics.

- T038: Observation of SDC Config/Target/Deviation status and propagation of conditions/Events absent
  - Missing: No watches on SDC CRDs, no status aggregation to per-device/aggregate conditions, and no Kubernetes Events.
  - Action: Add watches/indexes for SDC status resources; propagate standard conditions and emit Events; add envtest coverage.

- T039: Bounded backoff/jitter and terminal-vs-transient classification incomplete
  - Missing: Controllers use fixed RequeueAfter=10s; no exponential backoff/jitter and no runtime use of terminal/transient classification.
  - Action: Implement bounded backoff with jitter and apply terminal/transient classification (e.g., using model.IsTerminal) to avoid hot-looping; add tests.

- T040: Ordered finalization not implemented
  - Missing: No finalizers on managed resources; no ordered deletion of owned SDC intent, confirm/timeout flow, release of owned claims, or retention of recovery evidence.
  - Action: Add finalizers and finalize logic with timeouts; add tests that verify deletion ordering and durable effects.

- T041: Metrics/tracing instrumentation and in-Kind deployment verification absent
  - Missing: No Prometheus/Otel instrumentation in reconcilers, no build/load/deploy of provider images via T023 manifests, and no verification of Pods/Services/probes/RBAC or checks for secret/high-cardinality metric labels.
  - Action: Instrument with bounded metrics and OTel traces; add Dockerfile/build, load images into Kind, deploy via manifests, and provide tests/automation to verify deployment and metric label hygiene.

VERDICT f9da9ee86b1fe015: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./go`) or state in your evidence that grounding cannot reach it:
- `/usr/lib/go-1.24/bin/go`
