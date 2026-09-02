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
| `docker` | kind, containerlab | The lab runs 8 SONiC containers |
| `kind` | `scripts/provision.sh` | Cluster name defaults to `ainetops` |
| `kubectl` | everything | |
| `containerlab` | `scripts/lib/containerlab.sh` | SONiC fabric topology |
| `go` (1.24+) | controller build | Built from vendored source |
| `python3` | agents, test corpora | 3.13 for `agents/` |
| `gnmic` | capability gate | Pinned image, preloaded into kind |

`scripts/lib/preflight.sh` checks CPU, memory and storage headroom. It does NOT check
for the tools above or for metrics-server.

## Cluster context — read this before provisioning

`provision.sh` runs `make validate-crds` as a **server-side dry run against whatever
kubectl context is currently active**. If that context points at an unrelated cluster,
provisioning fails early with a confusing `namespaces "kubenet-system" not found`.

Check first:

```bash
kubectl config current-context     # expect kind-ainetops, or no context at all
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
kubectl top pods -n ainetops-agents      # must return rows before trusting any measurement
```

## Pinned images that are not built locally

`provision.sh` preloads pinned images into kind and WARNS (does not fail) when one is
missing from the local cache. Two are not produced by any build step in this repo:

```
grafana/flow-plugin@sha256:5c9d6b4d…
ghcr.io/ainetops/topology-generator@sha256:9a0b2b0d…
```

A missing image surfaces later as `ImagePullBackOff` on the dependent workload rather
than as a provisioning failure — `deployment/ui` is the observed case. Either make them
reachable from the host's registry cache or expect that workload to stay unavailable.

## Known-degraded workloads on a fresh bring-up

Observed 2026-09-02 with `--with-intent-tier`:

- `supervisor`, `slim` — Ready
- `mapper`, `allocator`, `deployer` — Running with restarts; the mTLS proxy to
  `slim.ainetops-agents.svc:46357` is the last thing logged before each restart
- `ui` — `ImagePullBackOff` (see above)

The intent tier is therefore usable for measurement but is NOT a clean bring-up. Record
that honestly in any readiness document rather than reporting healthy steady state.

## Fabric

`lab/profiles/sonic-vs` ships an ASan-instrumented `vlanmgrd` that can crash on startup,
leaving a leaf with no overlay devices. See `docs/FABRIC_BGP_EVPN_DEFERRED.md` D-A3. To
let provisioning continue past it and report the defect rather than fail closed:

```bash
AINETOPS_WAIVE_L2VNI_ADOPTION=1 ./scripts/provision.sh --profile sonic-vs --with-intent-tier
```
