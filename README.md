# agentic-netops - Autonomous intent-to-fabric operations.

[![CI](https://github.com/mairp/agentic-netops-srlinux/actions/workflows/ci.yaml/badge.svg)](https://github.com/mairp/agentic-netops-srlinux/actions/workflows/ci.yaml)
[![SR Linux](https://img.shields.io/badge/SR%20Linux-26.7.2-124191)](versions.lock.yaml)
[![EVPN/VXLAN](https://img.shields.io/badge/EVPN%2FVXLAN-BGP%20overlay-blue)](specs/001-agentic-netops-srlinux-evpn-fabric/contracts/lab-topology.md)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.31.6-326ce5)](versions.lock.yaml)
[![containerlab](https://img.shields.io/badge/containerlab-nokia__srlinux-0a7bbb)](lab/topology.clab.yml)
[![Tutorial](https://img.shields.io/badge/docs-TUTORIAL.md-green)](TUTORIAL.md)

[![AGNTCY](https://img.shields.io/badge/AGNTCY-intent%20tier-6f42c1)](agents/README.md)
[![LangGraph](https://img.shields.io/badge/LangGraph-supervisor-1c3c3c)](agents/supervisors/provisioning)
[![A2A](https://img.shields.io/badge/A2A-agent%20to%20agent-0b8043)](agents/README.md)
[![SLIM](https://img.shields.io/badge/SLIM-message%20bus-e37400)](deploy/agents/slim.yaml)
[![gNMI](https://img.shields.io/badge/gNMI-set%20%2B%20telemetry-00b3a4)](deploy/gnmi/gnmic.yaml)
[![Prometheus](https://img.shields.io/badge/Prometheus-metrics-e6522c)](deploy/observability/prometheus.yaml)
[![Grafana](https://img.shields.io/badge/Grafana-dashboards-f46800)](deploy/observability/dashboards)

Autonomous intent-to-fabric operations. You state intent in plain language; a multi-agent tier
decomposes it, allocates identifiers and submits declarative resources; Kubernetes
controllers reconcile them onto a live **Nokia SR Linux** EVPN/VXLAN fabric and *keep* them
that way -- repairing drift, surviving component failure, and releasing what it claimed
when intent is withdrawn.

The agent tier is not an add-on. It is how the network is driven: the fabric, the
controllers and the agents are three parts of one closed loop, with gNMI telemetry
feeding back into it. On SR Linux the southbound is gNMI end to end: the
fabric-executor writes with gNMI Set (JSON-IETF, transactional per request),
verifies with gNMI Get, and the collector subscribes over gNMI for telemetry.
There is no CLI scraping and no docker socket on the write path.

Everything below is self-contained: the instructions live here rather than in
a separate specification.

## Demo

Full walkthrough (~6½ min, 6x) — the intent tier end to end: three services
provisioned from plain-language prompts typed into the operator console (a
**vlan**, an **ip-vrf** with its prefix, and a **mac-vrf** stretched across
both leaves), each one confirmed through the mapper and allocator agents,
reported deployed, and then proven in the terminal with `kubectl` (the
`Network` resource `Ready`, its `ApplySucceeded` event, its spec) and on the
SR Linux leaf itself with read-only `sr_cli` show commands (the
network-instance and its subinterface, the tenant ip-vrf's route table and its
Type-5 EVPN route, the vxlan-interface's remote VTEP on both leaves).

<!-- DEMO VIDEO PLACEHOLDER — the SR Linux recording does not exist yet.
     It is produced by Phase 6 of
     specs/001-agentic-netops-srlinux-evpn-fabric/plan.md, on the operator's
     host, and accepted by testautomation/video/accept.py. T058 replaces this
     line with the uploaded asset URL once `accept.py --take final` reports
     `accept_pass: true`. Nothing is linked here until then: a video from the
     SONiC generation would be a claim about a fabric this tree no longer
     targets. -->

> **The SR Linux walkthrough has not been recorded yet.** This section describes
> the take that Phase 6 produces; the asset URL is filled in only after the
> recording exists and `accept.py` accepts it. The evidence file for the
> accepted take will land at
> `docs/media/agentic-netops-srlinux-intent-tier-demo-evidence.json`.
> The prompts, the proof commands and the acceptance criteria are fixed in
> advance in [docs/DEMO_VIDEO_PROMPT.md](docs/DEMO_VIDEO_PROMPT.md).

## The lab

![Fabric topology](docs/images/lab-topology.png)

Two spines, two leaves and four clients in containerlab (`nokia_srlinux`, type
`ixrd2l`), wired as a Clos with a dual-stack eBGP underlay (spines AS 65000,
leaf01 65101, leaf02 65102) and an EVPN/VXLAN overlay carried on iBGP AS 65535
with the spines as route reflectors. Tenant state lives only on the leaves.

Live gNMI telemetry from the fabric: gnmic subscribes to each SR Linux node's
native state paths on `:57400` (interface statistics and oper-state, BGP
neighbor session state, platform CPU/memory), Prometheus scrapes gnmic
directly, Grafana renders it. The subscriptions and the series they produce are
specified in
[contracts/telemetry.md](specs/001-agentic-netops-srlinux-evpn-fabric/contracts/telemetry.md)
and listed in
[deploy/observability/metrics-inventory.md](deploy/observability/metrics-inventory.md).

![Intent tier UI](docs/images/agent-ui.png)

The intent tier's console during a real run, wired to the live supervisor:
workers reachable over SLIM, the model reached through the LiteLLM gateway, and
the mapper's own interpretation of the request shown before anything is
allocated. The scenario cards are the constructs the supervisor itself
advertises on `GET /suggested-prompts` — vlan, mac-vrf, ip-vrf, acl — not a
separate hard-coded list, and every card names ports this site actually has.
The divider between the workflow canvas and the conversation is draggable
(mouse, touch, or arrow keys); the chosen split is remembered per browser.

![Deployment outcome](docs/images/agent-ui-outcome.png)

The end of the same transaction. The `submitted` payload is authoritative and
exists only because every apply succeeded; when convergence is still in flight
at the deployer's watch bound the console says exactly that, names the resource,
and points at the status tool — it does not report a success it has not
observed.

> **Screenshot provenance.** The Grafana and console screenshots under
> `docs/images/` were captured on the previous (SONiC) fabric; the console ones
> still show the tier faithfully, but the fabric node label and the telemetry
> panels are from that generation. They are replaced with SR Linux captures in
> Phase 4 of the plan (tasks T044 and T052). `docs/images/lab-topology.svg` has
> been redrawn for SR Linux; whether the accompanying `.png` was regenerated is
> recorded in [docs/images/README.md](docs/images/README.md).

**What works and what does not, on this target:** the intent tier, the
Kubernetes control plane and the operator console are unchanged from the
generation that was proven on the previous fabric — a provisionable request
still flows end to end (classification, interpretation, allocation, your two
explicit confirmations, then a real deployment transaction against the cluster:
translate pod-local, server-side dry-run, deterministic apply, rollback on
failure, convergence watch) and reports truthfully. The southbound has been
rewritten for SR Linux: an `srlprovider` Network controller renders the
accepted `Network` into gNMI Set operations through the host-side
fabric-executor and flips the `Network`'s `Ready` condition to True only after
per-node gNMI Get verification passes.

**None of that has been observed on an SR Linux fabric yet.** The offline
phases (renderer, executor, manifests, telemetry, documentation) are complete
and verified by build and unit tests; bring-up, the four constructs converging
and the recorded walkthrough are Phases 4–6 of
[the plan](specs/001-agentic-netops-srlinux-evpn-fabric/plan.md) and run on the
operator's host. Until those gates produce evidence under
`.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs/`, treat
every convergence claim in this repository as a design intent, not a result.
The equivalent results on the previous fabric, and the defects found getting
there, are recorded in
[docs/legacy/](docs/legacy/README.md) and
[docs/INTENT_TIER_SERVICE_TYPES.md](docs/INTENT_TIER_SERVICE_TYPES.md).

An endpoint naming a node or port the site does not have is refused by the
translator **before** anything is submitted, with the site's real names listed
(`ethernet1`, `ethernet2`, `ethernet3`, `wan1`, mapping to `ethernet-1/3` and
`ethernet-1/4`), instead of stranding an unrenderable `Network` on the cluster.
And a converged service is re-applied and re-verified every five minutes, so
`Ready=True` is a statement about the fabric now rather than about the moment it
first converged: drift — a hand edit, a reboot, another service's teardown
taking a shared object with it — is repaired, and said so. A single-shot
`POST /agent/prompt/stream`, however, stops at the supervisor's own iteration
bound, because the graph is built to provision only "after your two explicit
confirmations" and a one-shot request cannot supply them. The refusal is logged
as `audit refuse ... reason=request bound` — the tier declining to act, not
failing. The transaction contract, including what counts as a reportable
failure at each phase, is specified in
[docs/INTENT_TIER_DEPLOYMENT_TRANSACTION.md](docs/INTENT_TIER_DEPLOYMENT_TRANSACTION.md).

## What you get

| Piece | What it is |
| --- | --- |
| SR Linux fabric | 2 spines, 2 leaves (`ghcr.io/nokia/srlinux`, containerlab `nokia_srlinux` / `ixrd2l`), 4 Linux clients; dual-stack eBGP underlay, EVPN/VXLAN overlay on iBGP with spine route reflectors; underlay and overlay booted from startup configuration |
| Southbound | `pkg/fabricplan` renders each construct into gNMI Set operations, per-node gNMI Get checks and rollback ops; `cmd/fabric-executor` applies them over TLS on `:57400` |
| Controllers | `srlprovider` Network controller (apply → verify → `Ready`, 5-minute resync, rollback on delete) and the SRv6Service CRD + provider, built from vendored Go source |
| Observability | gNMIc collector on SR Linux native paths, OpenTelemetry collector, Prometheus, Grafana with fabric dashboards |
| Intent tier | AGNTCY supervisor + mapper/allocator/deployer agents over A2A/SLIM; the deployer runs the deployment transaction (translate → dry-run → apply → rollback → convergence watch) and reports truthfully |

## Prerequisites

Read **[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)** first — it lists the host tooling and two
traps that will otherwise cost you time:

- `provision.sh` dry-runs against your **current kubectl context**. Point it somewhere harmless
  or delete stale clusters first, or you get a confusing `namespaces "kubenet-system" not found`.
- `kubectl top` needs **metrics-server**, which kind does not install. Anything that measures
  resource usage silently returns nothing without it.

## Quickstart

For a guided walk-through — including driving the agents from plain language — see
**[TUTORIAL.md](TUTORIAL.md)**.

```bash
# bring the fabric up (~15-25 min on first run: image pulls + controller build)
./scripts/provision.sh --profile srlinux --cluster-name agentic-netops

# verify
make lab-qualify                          # gNMI Capabilities/Get/Set/Subscribe, persistence, EVPN
./tests/integration/fabric_verify.sh      # BGP sessions, EVPN routes, overlay data path
make verify-pins                          # every image/binary matches versions.lock.yaml
kubectl --context kind-agentic-netops get pods -A

# read-only proofs on a leaf
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance summary"
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance default protocols bgp neighbor"

# tear down (idempotent; safe to re-run)
./scripts/off.sh --delete-kind true
```

Add the agent tier:

```bash
# LLM provider: copy the example, uncomment one provider block, fill in the key.
# LLM_MODEL is always the model variable; its prefix picks the LiteLLM provider.
# .env is gitignored and becomes Secret/llm-provider at provision time.
cp .env.example .env
$EDITOR .env        # e.g. LLM_MODEL=openai/gpt-5, OPENAI_API_KEY=..., OPENAI_BASE_URL=https://api.openai.com/v1

./scripts/provision.sh --profile srlinux --cluster-name agentic-netops --with-intent-tier
kubectl --context kind-agentic-netops -n agentic-netops-agents get deploy
# UI on http://localhost:30000
```

## Known limitations — read before trusting a run

These are real, declared rather than hidden:

- **The SR Linux fabric has not been brought up from this tree yet.** Phases 1–3
  (topology, renderer, executor, manifests, telemetry, docs) are offline work
  verified by build, unit tests and static checks. Bring-up, construct
  convergence and the recorded walkthrough are Phases 4–6 and produce their
  evidence on the operator's host. Anything marked *verify live* in
  `specs/001-agentic-netops-srlinux-evpn-fabric/research.md` is a written
  expectation that no one has yet read back off the running image.
- **SRv6 is not applicable on this target.** The SR Linux container has no SRv6
  data plane. The capability gate records SRv6 entries as `not-applicable` with
  that reason (never `pass`), the site pins carry `cap-sai-srv6: "false"`, and
  `SRv6Service` objects reconcile to `Ready=False` with reason
  `CapabilityMissing`. The CRD, controller and dashboard stay in the tree so the
  absence is visible rather than quietly dropped.
- **An acl-only `Network` binds on subinterface index 0.** SR Linux binds ACL
  filters to subinterfaces, not to ports. A `Network` that declares only an
  access list has no subinterface of its own, so the renderer binds the filter
  on index 0 of the named port, creating it as `type routed` in the `default`
  network-instance if it does not exist. This mirrors the port-level binding of
  the previous generation and is the documented cost of keeping a construct the
  intent tier advertises.
- **Two pinned images have no local build step** (`grafana/flow-plugin`,
  `ghcr.io/agentic-netops/topology-generator`). Provisioning warns rather than fails; the dependent
  workload ends in `ImagePullBackOff`. (The intent tier's six images — supervisor, mapper,
  allocator, deployer, translator, UI — all build locally from `docker/Dockerfile.*`; note
  `intent::install` skips the docker build when the image tag already exists locally unless
  `INTENT_TIER_REBUILD=true`, so source changes need a rebuild or a forced rebuild to reach the
  cluster.)
- **IPv6 IRB gateway behaviour is unexercised on SR Linux.** The IPv6 Type-5
  origination defect recorded on the previous fabric was specific to that
  platform's routing stack and does not carry over as a known defect here — but
  nor has the IPv6 IRB path been driven on SR Linux. It is untested, not
  proven.
- **`docs/INTENT_TIER_OPS_READINESS.md` contains resource figures that were never measured.**
  They were produced before a cluster existed and before metrics-server was installed; real
  values differ by large factors. Re-measure before relying on that document.

## Repository layout

```
scripts/          provision.sh, off.sh, run-loop.sh, and lib/ (containerlab, rbac, qualify, intent_tier)
lab/              containerlab topology and the srlinux profile startup configuration
deploy/           Kubernetes manifests: controllers, kubenet, sdc, gnmi, observability, agents
pkg/fabricplan/   the deterministic SR Linux renderer (gNMI Set ops, Get checks, rollback)
cmd/              fabric-executor (gNMI backend), srlinux-provider, intent-translator
controllers/      SRv6Service and srlprovider Network controllers (Go); see README-CONTROLLERS.md
tests/            integration (fabric_verify, srlinux_gnmi_suite, evpn_suite) and unit suites
agents/           intent tier: supervisors, provisioning workers, test corpora
testautomation/   the recording driver and its acceptance checker
docs/             operations, security audit, dependencies, known defects, docs/legacy/ for the
                  previous fabric's findings
specs/            the spec, plan, research decisions, contracts and task list for this migration
versions.lock.yaml  every image and binary pin; enforced by `make verify-pins`
```

## Policies enforced in CI

**Jumbo MTU** — the lab standardises on underlay MTU 9216. VXLAN effective payload is 9166 (IPv4)
and 9162 (IPv6). Acceptance tests size packets to avoid fragmentation.

**Supply chain** — `make verify-pins` fails if any running image or binary drifts from
`versions.lock.yaml`, and `scripts/ci/supply_chain.sh` fails if a SONiC artifact appears in
the runtime manifests or the dependency graph. See [docs/SUPPLY_CHAIN.md](docs/SUPPLY_CHAIN.md).
