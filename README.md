# AINETOPS — SONiC EVPN/VXLAN fabric with an agentic intent tier

A reproducible, vendor-neutral reference platform: a containerlab SONiC fabric driven by
Kubernetes controllers, with an optional multi-agent "intent tier" that turns a plain-language
service request into declarative resources.

Everything below is self-contained. The `specs/` directory is intentionally untracked
(spec-kit working material), so this README carries the instructions rather than pointing at it.

## What you get

| Piece | What it is |
| --- | --- |
| SONiC fabric | 2 spines, 2 leaves, 4 clients in containerlab; BGP underlay, EVPN/VXLAN overlay |
| Controllers | SRv6Service CRD + provider, built from vendored Go source |
| Observability | OpenTelemetry collector, Prometheus, Grafana with fabric dashboards |
| Intent tier *(branch `002-agntcy-intent-tier`)* | AGNTCY supervisor + mapper/allocator/deployer agents, chat UI |

## Prerequisites

Read **[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)** first — it lists the host tooling and two
traps that will otherwise cost you time:

- `provision.sh` dry-runs against your **current kubectl context**. Point it somewhere harmless
  or delete stale clusters first, or you get a confusing `namespaces "kubenet-system" not found`.
- `kubectl top` needs **metrics-server**, which kind does not install. Anything that measures
  resource usage silently returns nothing without it.

## Quickstart

```bash
# bring the fabric up (~30-40 min on first run: image pulls + controller build)
./scripts/provision.sh --profile sonic-vs --cluster-name ainetops

# verify
./tests/integration/fabric_verify.sh      # BGP sessions, EVPN routes, overlay data path
make verify-pins                          # every image/binary matches versions.lock.yaml
kubectl --context kind-ainetops get pods -A

# tear down (idempotent; safe to re-run)
./scripts/off.sh --delete-kind true
```

Add the agent tier (from the `002-agntcy-intent-tier` branch):

```bash
./scripts/provision.sh --profile sonic-vs --cluster-name ainetops --with-intent-tier
kubectl --context kind-ainetops -n ainetops-agents get deploy
# UI on http://localhost:30000
```

## Known limitations — read before trusting a run

These are real, reproduced, and documented rather than hidden:

- **EVPN Type-5 routes are not originated.** The pinned `sonic-vs` FRR 10.5.4 build silently drops
  the `vni` line and never adopts the L3VNI. Type-2 and Type-3 work, including the bridged data
  path. See `docs/FABRIC_BGP_EVPN_DEFERRED.md` (D-A2).
- **`vlanmgrd` can crash on startup** (AddressSanitizer), leaving a leaf with no overlay devices,
  so the fabric cannot forward. Provisioning fails closed by design. To continue past it and have
  the defect reported rather than block the run:
  `AINETOPS_WAIVE_L2VNI_ADOPTION=1 ./scripts/provision.sh …` — see D-A3.
- **Two pinned images have no local build step** (`grafana/flow-plugin`,
  `ghcr.io/ainetops/topology-generator`). Provisioning warns rather than fails; the dependent
  workload ends in `ImagePullBackOff`. `deployment/ui` is the observed case.
- **`docs/INTENT_TIER_OPS_READINESS.md` contains resource figures that were never measured.**
  They were produced before a cluster existed and before metrics-server was installed; real
  values differ by large factors. Re-measure before relying on that document.

## Repository layout

```
scripts/          provision.sh, off.sh, and lib/ (containerlab, rbac, qualify, intent_tier)
lab/              containerlab topology and the sonic-vs profile bootstrap
deploy/           Kubernetes manifests: controllers, kubenet, observability, agents
controllers/      SRv6Service controller (Go)
tests/            integration (fabric_verify, cycles_runner) and unit suites
agents/           intent tier: supervisors, provisioning workers, test corpora (002 branch)
docs/             operations, security audit, dependencies, known defects
versions.lock.yaml  every image and binary pin; enforced by `make verify-pins`
```

## Policies enforced in CI

**Deny-list** — keeps the platform vendor-neutral. No SR Linux runtime artifacts, no proprietary
NED references outside research citations, no Compose/standalone platform-app placements under
`controllers/`, `config/`, `scripts/`, `examples/`, `tests/`. Reproduce locally with
`make denylist`; see `.github/workflows/denylist.yml`.

**Jumbo MTU** — the lab standardises on underlay MTU 9216. VXLAN effective payload is 9166 (IPv4)
and 9162 (IPv6); with 3 SRv6 SIDs it is ~9120. Acceptance tests size packets to avoid
fragmentation.

**Supply chain** — `make verify-pins` fails if any running image or binary drifts from
`versions.lock.yaml`.
