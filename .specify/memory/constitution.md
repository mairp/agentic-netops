# agentic-netops-srlinux Constitution

<!-- Sync Impact Report
Version: 1.0.0 (initial ratification for the SR Linux target)
Derived from: mairp/agentic-netops (SONiC EVPN/VXLAN fabric), same operating
principles, network operating system replaced by Nokia SR Linux.
Templates checked: plan-template ✅ spec-template ✅ tasks-template ✅
-->

## Core Principles

### I. The fabric's truth wins (NON-NEGOTIABLE)
No component ever reports a success it has not observed on the device. A
`Network` is `Ready=True` only after every rendered operation was accepted by
the node AND every per-node verification read back the expected state over
gNMI. The deployer reports `submitted` only because every apply succeeded, and
says "still converging" or "failed" otherwise, naming the resource and the
check. Screenshots and log lines are never evidence; gNMI Get bodies, kubectl
JSON and `sr_cli` output are.

### II. Fail closed, name the defect
Every gate (preflight, capability qualification, fabric verification, CI
policy) stops the pipeline and prints the failing check. A capability the
platform does not have (SRv6 on the SR Linux container) is declared absent,
gated as not-applicable with a written reason, and never silently skipped or
faked. Refusals of unsupported intent are explicit and name the supported
alternative.

### III. One declarative path to the device
The only write path to the fabric is the fabric-executor's gNMI Set against the
SR Linux management endpoint, driven by the deterministic renderer in
`pkg/fabricplan`. No `docker exec`, no CLI scraping, no hand edits on nodes.
Every op is idempotent (a re-apply of a converged service writes nothing new);
every plan carries its own verification checks and rollback ops.

### IV. Immutable pins and supply chain
Every image and binary is pinned by immutable digest or tag-resolved commit in
`versions.lock.yaml` and enforced by `make verify-pins`. The fully open-source
distribution runs on the public `ghcr.io/nokia/srlinux` image; no SONiC
artifact may appear in runtime manifests or the dependency graph
(`scripts/ci/supply_chain.sh` enforces it).

### V. Nothing else changes
The intent tier (AGNTCY supervisor, mapper, allocator, deployer over A2A/SLIM),
the Kubernetes control plane (kubenet, kuid, CRDs), the observability stack and
the operator console keep their contracts. The migration touches the NOS
boundary: topology, bootstrap, renderer, executor backend, verification
suites, telemetry paths, dashboards and documentation. Construct vocabulary
(vlan, mac-vrf, ip-vrf, acl) and the `Network` schema are unchanged.

## Engineering Constraints

- Go 1.22 toolchain, vendored dependencies (`-mod=vendor`), static binaries.
- Python agents on `uv` lockfile; UI on `npm ci`.
- Lab: containerlab `nokia_srlinux` kind, 2 spines / 2 leaves / 4 Linux
  clients, jumbo MTU 9216, management network 172.31.0.0/16.
- gNMI: TLS on 57400, JSON_IETF, credentials generated per lab and stored as
  Kubernetes Secrets; never committed.
- Evidence for every live claim lands under `.wiggum/features/<slug>/gates/proofs/`.

## Development Workflow

Spec-driven: `spec.md` → `plan.md` → `tasks.md` (this repository's
`specs/001-agentic-netops-srlinux-evpn-fabric/`). The wiggum orchestrator drives
`tasks.md` phase by phase (`scripts/run-loop.sh`); a phase advances only after
its critic gate approves evidence. Offline phases (renderer, executor,
manifests, docs) are verified by `go build`, `go test`, `ruff`, `pytest`,
`npm run build` and static checks; live phases are verified on the host that
runs the lab (`scripts/provision.sh`, `make lab-qualify`,
`tests/integration/fabric_verify.sh`, the four constructs converging to
`Ready=True`, and the recorded walkthrough accepted by `testautomation/video/accept.py`).

## Governance

This constitution supersedes ad-hoc practice. Amendments are recorded here with
a version bump and a Sync Impact Report. Every PR and every wiggum gate must
show compliance with Principles I–IV; complexity beyond Principle V must be
justified in `plan.md`.

**Version**: 1.0.0 | **Ratified**: 2026-09-13 | **Last Amended**: 2026-09-13
