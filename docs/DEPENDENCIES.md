# Dependencies and cluster prerequisites

What must exist BEFORE `scripts/provision.sh` can bring up a usable environment, and
what must additionally exist before any phase whose criteria say *measure*, *record*,
*observe* or *run a drill*.

Written 2026-09-02 after phase-10 acceptance criteria could not be satisfied honestly:
`kubectl top` was named as the measurement method, but `metrics-server` is not part of
a kind cluster, so the command could never have worked. See "Measurement" below.

## Host tooling

| Tool | Used by | Notes |
| --- | --- | --- |
| `docker` | kind, containerlab | The lab runs 4 Nokia SR Linux nodes and 4 Linux clients |
| `kind` | `scripts/provision.sh` | Cluster name defaults to `agentic-netops` |
| `kubectl` | everything | |
| `containerlab` | `scripts/lib/containerlab.sh` | SR Linux fabric topology (kind `nokia_srlinux`) |
| `go` (1.24+) | controller build | Built from vendored source |
| `python3` | agents, test corpora | 3.13 for `agents/` |
| `gnmic` | capability gate, bootstrap, telemetry | Pinned; the host binary is used by `scripts/lib/containerlab.sh bootstrap` and the suites, the pinned image by the in-cluster collector |

`scripts/lib/preflight.sh` checks CPU, memory and storage headroom. It does NOT check
for the tools above or for metrics-server.

## Cluster context — read this before provisioning

`provision.sh` runs `make validate-crds` as a **server-side dry run against whatever
kubectl context is currently active**. If that context points at an unrelated cluster,
provisioning fails early with a confusing `namespaces "kubenet-system" not found`.

Check first:

```bash
kubectl config current-context     # expect kind-agentic-netops, or no context at all
kind get clusters                  # delete leftovers you do not need
```

## Measurement — REQUIRED for the operational-readiness phases

`kubectl top` needs **metrics-server**, which kind does NOT install. Without it the
command returns nothing at all, and any phase asking for measured CPU/memory cannot be
satisfied from real data.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# REQUIRED on kind: kubelet serves self-signed certs, which metrics-server rejects by
# default, so it installs but never becomes Ready.
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s
kubectl top pods -n agentic-netops-agents      # must return rows before trusting any measurement
```

## Pinned images that are not built locally

`provision.sh` preloads pinned images into kind and WARNS (does not fail) when one is
missing from the local cache. Two are not produced by any build step in this repo:

```
grafana/flow-plugin@sha256:5c9d6b4d…
ghcr.io/agentic-netops/topology-generator@sha256:9a0b2b0d…
```

A missing image surfaces later as `ImagePullBackOff` on the dependent workload rather
than as a provisioning failure — `deployment/ui` is the observed case. Either make them
reachable from the host's registry cache or expect that workload to stay unavailable.

## Known-degraded workloads on a fresh bring-up

Observed 2026-09-02 with `--with-intent-tier`:

- `supervisor`, `slim` — Ready
- `mapper`, `allocator`, `deployer` — Running with restarts; the mTLS proxy to
  `slim.agentic-netops-agents.svc:46357` is the last thing logged before each restart
- `ui` — `ImagePullBackOff` (see above)

The intent tier is therefore usable for measurement but is NOT a clean bring-up. Record
that honestly in any readiness document rather than reporting healthy steady state.

## Fabric

`lab/profiles/srlinux` pins `ghcr.io/nokia/srlinux:26.7.2`, resolved to the
immutable digest recorded in `versions.lock.yaml` and enforced by
`make verify-pins`. Pull it before provisioning:

```bash
docker pull ghcr.io/nokia/srlinux:26.7.2
docker images --digests | grep srlinux     # must match the pinned digest
```

Each node needs roughly 1.5-2 GiB of RAM; the four-node fabric plus the kind
cluster fits the 16 GiB minimum above, with the intent tier taking the rest of
the headroom.

The capability gate fails closed on gNMI Capabilities/Get/Set/Subscribe,
configuration persistence across a container restart, and EVPN Type-2/3/5 with
remote-VTEP learning and overlay traffic. SRv6 entries are recorded as
`not-applicable` with their reason (the SR Linux container has no SRv6 data
plane), never as `pass`.

No SONiC artifact may appear in the runtime manifests or the dependency graph;
`scripts/ci/supply_chain.sh` enforces that. The previous fabric's findings are
kept under `docs/legacy/sonic/`.
