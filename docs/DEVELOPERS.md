# Agentic NetOps Developers Guide

This document describes development workflows and responsibilities for the
Agentic NetOps **Nokia SR Linux** EVPN/VXLAN fabric implementation.

- Build binaries: `make build`
- Run envtest: `make test-envtest`
- Static checks: `make test-static`
- Verify pins and API shapes: `make verify-compat`
- Supply-chain checks: `make supply-chain`; CI also runs the deny-list and
  provenance jobs
- Renderer unit tests and goldens: `go test -mod=vendor ./tests/unit ./pkg/...`
- Path register guard: `make verify-register`

## The southbound contract

The only write path to the fabric is the fabric-executor's gNMI Set against the
SR Linux management endpoint, driven by the deterministic renderer in
`pkg/fabricplan`. There is no `docker exec`, no CLI scraping and no hand edit on
a node. Every op is idempotent; every plan carries its own verification checks
(gNMI Get assertions) and its rollback ops, and rollback never deletes an object
the plan did not create.

The device-side shapes the renderer emits are fixed in
`specs/001-agentic-netops-srlinux-evpn-fabric/contracts/srlinux-render-contract.md`.
Change them there first; the golden plans under
`tests/unit/testdata/fabricplan/` are byte-stable and will fail loudly
otherwise.

## RBAC and field ownership

- The provider uses server-side apply with field manager
  `agentic-netops-srlinux-provider`.
- ClusterRole scopes are minimal: events, kubenet `NetworkDevice`/status, SDC
  `Config`/`Target`.
- Do not widen verbs without justification.
- The provider's egress to the fabric is scoped by the
  `allow-fabric-gnmi-egress` NetworkPolicy to `172.31.0.0/16` port 57400; the
  intent tier has no such rule and must never get one.

## Logging and redaction

- Do not log secrets, usernames or passwords.
- Emit events with reason strings from `pkg/reasons`; use standard Condition
  types.
- When a device rejects a Set, surface the node's error text verbatim — a
  paraphrased device error is a lost defect.

## Reproducibility

- All container images are built with `CGO_ENABLED=0` (static) and use
  distroless:nonroot runtime.
- Go builds are vendored (`-mod=vendor`).
- Avoid reliance on local state; render deterministically from inputs.

## Deny-list policy

- The supply-chain policy is inverted for this target: SONiC artifacts are
  forbidden in the runtime manifests and the dependency graph. See
  `docs/SUPPLY_CHAIN.md`; run `make denylist` locally to reproduce the CI policy.
