# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

Unmet or unclear criteria

- T027a — Missing required server-side dry-run/envtest coverage:
  - The spec requires “add CEL validation and server-side dry-run/envtest coverage per contracts/crd-api.md:52-70,137.” There are no envtest or dry-run tests anywhere in the repo. Evidence even states “go test ./... passes (no tests for these packages yet).” You must add envtest that installs config/crd/bases/ainetops.io_srv6services.yaml into a test API server and validates sample CRs (positive/negative) using server-side dry-run.

- T028 — NetworkDevice selection, dependency watches/indexes, and readiness gates not implemented:
  - The sonicprovider controller is wired to corev1.ConfigMap with a label filter (controllers/sonicprovider/controller.go: For(&corev1.ConfigMap{})), not the required Kubenet NetworkDevice resource. The comment admits this is a placeholder. Implement actual watch/selection for Kubenet’s NetworkDevice CR.
  - Dependency field indexes are only a scaffold for ConfigMaps (controllers/sonicprovider/indexes.go) and are never registered in the manager (cmd/sonic-provider/main.go never calls SetupIndexes).
  - No current-generation readiness gates or standard Conditions/Events are set anywhere; reasons.go exists but is unused. Implement conditions and gating logic before emitting any downstream changes.
  - No equivalent watches/gates for SRv6Service are implemented beyond a trivial watcher; no dependency gating is present in controllers/srv6service/controller.go.

- T029 — Compatibility-set validation incomplete and not integrated:
  - pkg/compat/compat.go is a minimal placeholder; it only checks for non-empty fields and a stub SRv6 capability flag. There is no validation of pinned telemetry/topology label contract, mappings, schema commits, or upstream API versions as required.
  - There is no controller integration using this validator to set stable reasons (e.g., SchemaMismatch), gate reconciliation, and ensure no changed SDC Config is emitted on mismatch. Implement end-to-end usage in reconciliation.

- T029a — OpenConfig-vs-SONiC-native register missing:
  - No per-path register exists documenting chosen OpenConfig vs. native YANG paths, gaps, justifications, or a CI check to prevent regressions. Produce the register and wire a CI/test to enforce it.

- T030 — Abstract-model normalization not implemented:
  - No code normalizes the canonical model or rejects incomplete/unknown/conflicting constructs before rendering. Add normalization and strict validation routines over pkg/model types and test them.

- T031 — Interface/loopback/MTU and dual-stack IPv4 /31 plus IPv6 underlay renderers not implemented:
  - No renderer exists for interfaces/loopbacks/MTU or addressing. Implement renderers and corresponding tests.

- T032 — BGP global/neighbor and EVPN AF renderers not implemented:
  - No code renders BGP global, neighbors, or EVPN address families. Implement and test.

- T033 — VLAN, bridge, VXLAN NVO, VTEP, L2VNI renderers not implemented:
  - No renderer present. Implement and test.

- T034 — VRF, L3VNI, RD/RT, Type-5, symmetric-IRB, SRv6 locator/MySID, H.Encaps.Red, ordered SID-list steering, transit End, egress End.DT46 renderers not implemented:
  - No renderer present. Implement and test.

- T035 — Deterministic ordered output, stable generated names, canonical hashes, compatibility annotations, owner references, and minimal scoped paths not implemented:
  - No composition layer exists. Implement deterministic composition and hashing, include owner references for NetworkDevice/SRv6Service, and limit field ownership per FR-007/FR-009.

- T036 — Offline SDC/schema validation integration missing:
  - No integration with SDC offline validation or logic to emit no changed Config on validation failure. Implement validation step and guard writes.

- T037 — Server-side apply and field manager policies not implemented:
  - No SSA usage with a dedicated field manager, priority/operation/revertive/deletion policies. Implement SSA semantics as required.

- T038 — Observation of SDC Config/Target/Deviation status and propagation not implemented:
  - No code watches SDC status or emits standard per-device and aggregate conditions/Events. Implement status observation and propagation.

- T039 — Bounded backoff/jitter and terminal-vs-transient error classification not implemented:
  - Reconciliation lacks retry classification and bounded backoff with jitter. Implement error classification and backoff policy.

- T040 — Ordered finalization not implemented:
  - No finalizers exist to delete owned SDC intent, confirm/timeout, release claims, or retain manual recovery evidence. Implement finalization flow and durable evidence.

- T041 — Metrics/tracing instrumentation and in-cluster deployment verification not implemented:
  - No Prometheus metrics or OTel traces in reconciles; no Kind deployment artifacts/proof that provider image is built/loaded/deployed using T023’s manifests; no verification of Pods, Services, probes, RBAC, or metric-label hygiene. Instrument and provide deployment verification.

Notes on partially met items

- T026 — Provider manager scaffold largely present:
  - Health/readiness probes, leader election, and graceful shutdown are implemented (cmd/sonic-provider/main.go).
  - Pinned dependencies are present (go.mod versions; pkg/version/pins.go).
  - Reconciler scaffold exists with stable reasons and a placeholder indexes file. However, these scaffolds are not enough to satisfy downstream tasks (T028 and beyond).

- T026a — SRv6 controller scaffold present:
  - Binary has probes, leader election, graceful shutdown; type registration present; reconciler watches SRv6Service. Pinned dependencies match T026.

- T027 — Canonical internal structs exist:
  - pkg/model/types.go defines interfaces, loopbacks, BGP, network instances (with RD/RTs), VLAN/VNI/VXLAN, IRB, IPv6 underlay fields, locators, MySIDs, SID lists/behaviors, and steering policies. This meets the struct-definition portion; renderers/normalization are still missing in later tasks.

Verdict rationale

Only T026, T026a, and T027 appear satisfied. T027a is incomplete due to missing required envtest/dry-run coverage. All subsequent Phase 4 obligations (T028–T041) are absent or only present as non-functional scaffolds. Per the rules, any unmet or unclear criterion requires rejection.

VERDICT 2253769d30bdb21e: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./go`) or state in your evidence that grounding cannot reach it:
- `/usr/lib/go-1.24/bin/go`
