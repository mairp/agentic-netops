<!-- vocabulary: historical -->
# Cluster rebuild on the committed pins — findings and pending work

Note: This document describes the fabric and operator surfaces as they existed before feature 003 (Datacenter Service Constructs). Service names in this file are historical provenance, not vocabulary an operator can ask for.

**Date:** 2026-09-04
**Trigger:** a provisioning request failed with
`worker 'worker' is unavailable: A2A JSON-RPC error (code=-32603): [SSL: CERTIFICATE_VERIFY_FAILED]`
**Scope:** root-causing that error, then rebuilding the kind lab against the pins committed in
`versions.lock.yaml` (k8s v1.31.6 / kind v0.27.0) after the fix required a cluster the old
v1.29.4 lab could not provide.

---

## TL;DR

| Area | State |
|---|---|
| Original SSL error | **Fixed and verified** |
| Cluster on committed pins | **Rebuilt** (k8s v1.31.6, kind v0.27.0) |
| Intent tier + operator UI | **Up** — <http://localhost:30000> returns 200 |
| Identifier allocation (KUID) | **Fixed with fallback** — VLAN remains on KUID; VNI/RT use Lease fallback when pinned `kuid-server` rejects them |
| Fabric overlay (leaf02) | **Fixed in live lab** — EVPN_NVO declared, VTEPs waited/bound, bgpd adopted L2 VNI |
| From-scratch `provision.sh` | **Partially addressed, not fully proven** — tier install is independent of the fabric gate; full clean rebuild still not rerun |

Ten defects were found and fixed in tracked files during the rebuild. The follow-up
below closes the two open items and addresses the ordering fragility; a full clean
`provision.sh` rebuild still needs to be rerun.

**Follow-up applied 2026-09-04.** The pending fabric and allocation findings below
were fixed in tracked files after this report was written:

- Fabric: `configure-fabric-bgp.sh` now writes `EVPN_NVO|nvo1`, waits for the L2
  VTEP device, restarts `orchagent`/`vxlanmgrd` once if it is missing, bridges the
  VTEP before bgpd starts, and uses the corrected bgpd VNI adoption grep in the
  restart hook.
- Allocation: the allocator now falls back to atomic Kubernetes `Lease` objects in
  `kuid-system` for pools the pinned aggregated KUID server cannot serve. L2 and L3
  VNI leases share the same `evpn-vni` pool, so they cannot receive duplicate IDs.
- Ordering: `provision.sh --with-intent-tier` attempts the intent tier before the
  SONiC fabric gate and records tier failure without preventing fabric diagnostics.

Verification from the follow-up: 121 Python unit tests passed, Go unit/package tests
passed, RBAC probe passed with 35 assertions, live allocator fallback allocated and
released VNI leases, and live fabric bootstrap exited 0 with both leaves carrying
`EVPN_NVO=vtep1`, `vtep1-100` on `Bridge`, `vtep1-2000` on `VrfBlue`, and bgpd
adopting L2 VNI 100.

---

## The umbrella finding: NetworkPolicy became enforced

Six of the ten fixed defects share one cause, and it is the single most useful thing in this
document.

`deny-all-by-default` exists in both `agentic-netops-system` (`deploy/rbac/base.yaml`) and
`agentic-netops-agents` (`deploy/agents/namespace-rbac.yaml`):

```yaml
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]     # no allow rules
```

That denies **all** ingress and **all** egress for every pod in those namespaces, the Kubernetes
API server included. It was **inert** under kind v0.22's kindnetd, which did not implement
NetworkPolicy. The pinned `kindnetd v20250214` **does** enforce it.

So a set of workloads that had "always worked" stopped working the moment the lab moved onto its
own committed pins. Nothing about the policy changed; the CNI started honouring it.

Failure shapes seen, all from this one cause:

- `dial tcp 10.96.0.1:443: i/o timeout` (generator Job, both controllers, allocator)
- a pod **Ready but silently degraded** — the system `otel-collector` kept running and merely
  logged `failed to list *v1.Pod ... i/o timeout`, so its telemetry was unenriched with no
  visible failure
- `ERR_EMPTY_RESPONSE` in the browser, with the UI pod healthy and serving HTML on
  `127.0.0.1:3000` — nothing admitted the NodePort connection
- a collector exiting `2` with no useful log, because it could not reach ClickHouse

### Two of the policies meant to permit this were already broken

Not merely missing — present and non-functional, invisibly, for as long as the CNI ignored them:

`apiserver-egress-cluster-clients` (T050) had **two independent bugs**:

1. Selector `app In (intent-allocator, intent-deployer)` against pods actually labelled
   `app: allocator` / `app: deployer` → **matched zero pods**.
2. Destination `namespaceSelector: kubernetes.io/metadata.name: kube-system` on port 443. The API
   server is a hostNetwork static pod behind a Service ClusterIP that DNATs to the node address, so
   no namespace or pod selector can match it, and the matched port is **6443**, not 443.

It has been repaired in place rather than replaced, keeping T050's name and intent.

### How to express "egress to the API server" here

Verified experimentally in an isolated `np-test` namespace:

- ClusterIP-only (`10.96.0.1/32:443`) → **does not work**. kindnetd matches the **post-DNAT**
  destination, i.e. `<node-ip>:6443` (`curl` exit 28, timeout).
- A literal node CIDR works but is **not portable**: kind's docker network takes a
  Docker-assigned IPv4 subnet (`172.30.0.0/16` on this host, something else on the next). It is
  pinned nowhere, so a hardcoded CIDR silently stops matching on a rebuild elsewhere.

The form now used is host-independent — any address, but only the two API ports, minus the
containerlab management subnet (which **is** pinned, in `kind.sh` and `lab/topology.clab.yml`):

```yaml
egress:
- to:
  - ipBlock:
      cidr: 0.0.0.0/0
      except: [172.31.0.0/16]
  ports: [{protocol: TCP, port: 443}, {protocol: TCP, port: 6443}]
```

Verified this keeps SC-005's device-network denial intact: API server → 200, `172.31.0.21` →
still times out.

Workloads opt in with `agentic-netops.io/needs-apiserver: "true"`, declared where the workload is
defined.

---

## Fixed defects

| # | Defect | Symptom if unfixed | Files |
|---|---|---|---|
| 1 | Allocator verified TLS against certifi, which holds no cluster CA | the reported `CERTIFICATE_VERIFY_FAILED` | `agents/provisioning/allocator/kuid.py`, `agents/config/config.py` |
| 2 | Allocator pod had `automountServiceAccountToken: false` — no token **and no CA bundle** — contradicting T039, which names it a cluster-API identity | no credential, no trust anchor | `deploy/agents/allocator.yaml` |
| 3 | `_CACERT_FILE` defined but never used in the audit seam | k8s Event emission failing silently the same way | `agents/common/audit.py` |
| 4 | `deny-all-by-default` blocks API egress (see above) | generator Job, `sonic-provider`, `srv6-controller`, `otel-collector`, allocator all cut off | `deploy/rbac/base.yaml`, `deploy/agents/namespace-rbac.yaml` + 4 workload manifests |
| 5 | `apiserver-egress-cluster-clients` matched zero pods and pointed nowhere valid | the intended allowance did nothing | `deploy/agents/namespace-rbac.yaml` |
| 6 | No ingress policy for the UI | **`ERR_EMPTY_RESPONSE`** | `deploy/agents/namespace-rbac.yaml` (`ui-ingress`) |
| 7 | No intra-tier ingress policy | agent collector could not reach ClickHouse | `deploy/agents/namespace-rbac.yaml` (`tier-intra-ingress`) |
| 8 | Prometheus metric namespace `agentic-netops` — hyphens are invalid in metric names | `sonic-provider` **panics at startup**: `"agentic-netops_sonicprovider_applies_total" is not a valid metric name` | `controllers/sonicprovider/controller.go` |
| 9 | Nothing ever created the `agent_analytics` database | collector `CrashLoopBackOff`: `code: 81, message: Database agent_analytics does not exist` | `deploy/agents/telemetry.yaml` |
| 10 | Tier images never built by anything; `install-deps.sh` checked tool *presence*, not version | guaranteed `ImagePullBackOff` on a clean host; `kubectl` stuck at v1.29.4 against a v1.31.6 cluster | `scripts/lib/intent_tier.sh`, `scripts/install-deps.sh` |

### #8 in detail — a rebrand artifact

The `ainetops` → `agentic-netops` rename (f16b27dc) rewrote a Prometheus `Namespace:` string along
with everything else. Metric names must match `[a-zA-Z_:][a-zA-Z0-9_:]*`, and `Namespace` is
prefixed verbatim, so the composed name carried a hyphen and `MustRegister` panicked the
controller before it could serve. Fixed to `agentic_netops`. Nothing queries the old name, so no
dashboard or alert breaks.

### A wrong turn worth recording — `kubectl --request-timeout`

An earlier attempt at #4 bounded the generator Job's kubectl calls with `--request-timeout=30s`.
**This was wrong and caused a failure of its own.** `--request-timeout` sets a client-config
override, which makes the merged config differ from the pure default — and kubectl only falls back
to **in-cluster** configuration when the merged config *is* the default. With the flag, every call
in the pod silently addressed `http://localhost:8080`:

```
A: NO  --request-timeout  →  https://10.96.0.1:443   (in-cluster)
B: WITH --request-timeout →  http://localhost:8080   (connection refused)
```

The calls are now bounded with coreutils `timeout 30 kubectl …`, which bounds from outside and
leaves config resolution alone. kubectl has no client-side timeout by default, so bounding them
is still necessary: an unreachable API server otherwise blocks forever, the container never exits,
`restartPolicy: OnFailure` never fires, and the caller's bounded wait expires instead.

---

## Pending / broken

### 1. Fabric overlay — leaf02 has no VXLAN interfaces

**Status:** blocks `provision.sh` from completing, and the overlay cannot forward.

`provision.sh` aborts at fabric bring-up:

```
[fabric-bgp] WARN: no vtep carrying vni 1000 on clab-agentic-netops-fabric-leaf02
[fabric-bgp] leaf02: zebra has no VNI 100 (attempt 1..3) — restarting zebra then bgpd
[fabric-bgp] ERROR: leaf02: bgpd never adopted L2 VNI 100 after 3 restarts
[provision] lab bootstrap failed
```

Observed state — identical CONFIG_DB on both leaves, divergent outcome:

| | leaf01 | leaf02 |
|---|---|---|
| vlan devices | `Vlan100@Bridge`, `Vlan2000@Bridge` | `Vlan2000@Bridge` only (initially) |
| vxlan devices | `vtep1-100`, `vtep1-2000` | **none** |
| `EVPN_NVO` | absent | absent |
| orchagent `unable to find EVPN VTEP` | 0 | 673+ (hot loop, ~650/s, rate-limited by rsyslog) |

`Vlan100` was created on leaf02 (`RTM_NEWLINK` 20:39:19) and **deleted 30s later**
(`RTM_DELLINK` 20:39:49).

**Analysis.** `EVPN_NVO` is configured on *neither* leaf, so `updateVrfVNIMap` can never resolve
the EVPN VTEP. leaf01 won the startup race anyway; leaf02 lost and orchagent wedged. This looks
like a genuine config omission plus a timing race, not a one-off.

**Recovery attempts, all unsuccessful:**
1. Adding `EVPN_NVO|nvo1 source_vtep=vtep1` → no convergence within 60s.
2. Recreating `Vlan100` manually → the device sticks, but `vxlanmgrd` does not act.
3. Deleting and re-asserting `VXLAN_TUNNEL_MAP|vtep1|map_100_Vlan100` → still no vxlan devices.

**Context:** `docs/FABRIC_BGP_EVPN_DEFERRED.md` records this overlay working end-to-end on
2026-09-01 (client01 ↔ client02, 0% loss). `configure-fabric-bgp.sh` carries extensive comments
from repeated prior fixes to this same race, with leaf01/leaf02 swapping roles between runs. So
this is a **flaky regression in a known-fragile area**, not a permanent breakage.

**Likely next steps:** add `EVPN_NVO` to the CONFIG_DB intent the script applies; make the script
*wait for* the vtep devices (it currently waits for `Bridge` but assumes `vtep1-*` exists, so the
enslave block is silently skipped when they are late); consider restarting orchagent when the
`unable to find EVPN VTEP` loop is detected.

### 2. KUID allocation — `uint64` defect in the pinned kuid-server

**Status:** provisioning requests will fail at allocation.

`[kubenet-install] WARN: kuid-server did not accept index writes; allocation will fail`

| Index kind | Result |
|---|---|
| `VLANIndex` | **works** — `fabric-vlan` Ready, 100–4000 |
| `GENIDIndex` | fails |
| `EXTCOMMIndex` | fails |

Two distinct failures on the genid/extcomm kinds:

- **With `minID`/`maxID`:** `apiserver panic'd ... unsupported type: uint64` → HTTP 503. Those
  fields are `*uint64`, which `structured-merge-diff v4.4.1` cannot walk during field management.
- **Without them:** rejected as `invalid GENID Type` for *every* documented value (`16bit`,
  `32bit`, `48bit`, `64bit`). The error dumps an all-zero object — empty `metadata.name` included —
  suggesting the external→internal conversion drops the spec.

`VLANIndex` is unaffected because it has no `type` field and no `uint64` range.

**Net effect:** VLANs can be claimed; VNIs (L2/L3) and route-targets cannot. The k8s upgrade *did*
fix the earlier `not yet ready to handle request` problem (kuid-server needs ≥1.30 for
`ValidatingAdmissionPolicy` v1) — this is a separate, upstream defect.

**Options:**
- Pin a different/newer `kuid-server` that fixes the uint64 handling.
- Move allocation to the CRD-backed `id.kuid.dev` path — but that needs a working `kuid-controller`
  to reconcile Claims, and its image is a `sha256:2222…` placeholder.

### 3. Ordering fragility — a data-plane failure blocks the control tier

`provision.sh` installs the intent tier **last**, after the fabric bootstrap and the capability
gate, under `set -euo pipefail`. The ordering comment explains the reasoning (a tier problem must
not leave the fabric unconfigured), and that reasoning is sound — but the converse now bites: a
lab overlay race prevents the operator UI from deploying at all.

The tier was installed directly via `intent::install` to recover the UI in this session. Worth
deciding whether the tier install should be independent of the fabric gate.

### 4. Pre-existing, not rebuild-related

- **Placeholder image digests** — `kubenet-controller` (`sha256:1111…`), `kuid-controller`
  (`sha256:2222…`), the four SDC components, and `sonic-provider`'s registry image
  (`sha256:9999…`) are all unpullable. Identical set was in `ImagePullBackOff` on the old cluster.
- **Two synthetic `tooling:` digests** in `versions.lock.yaml` — `grafana/flow-plugin` and
  `ghcr.io/agentic-netops/topology-generator` — end in obviously fabricated hex (`…e1f2a3b4`).
  Never real pins.
- **`PrometheusRule` fails to apply** — needs the Prometheus Operator CRDs, which this stack does
  not install. `|| true`-guarded, non-blocking.
- **Grafana/Prometheus NodePorts** (30300/30090) are unreachable: `config/kind/cluster.yaml` maps
  those host ports, but the Services are `ClusterIP`, so nothing is behind them.
- **UI → backend URLs** are cluster-internal `.svc` names baked into the browser bundle
  (`VITE_SUPERVISOR_API_URL=http://supervisor.agentic-netops-agents.svc:9090`). A browser on the
  host cannot resolve those. The page loads; whether operator chat works end-to-end from the host
  browser is **unverified**.

---

## Reproducibility — what is and is not proven

**Proven:** all fixes live in tracked files, not in live-cluster state. `install-deps.sh` now
enforces pinned `kubectl`/`kind` versions rather than accepting whatever is present.
`intent_tier.sh` now builds missing tier images (idempotent; `INTENT_TIER_REBUILD=true` forces)
and treats a build or load failure as fatal instead of warning and continuing.

**Not proven:** a clean teardown-and-reprovision has **not** been run. It would currently still
fail, because Pending #1 aborts `provision.sh` before the tier deploys. Until that run happens,
"works from scratch" is an expectation, not a verified claim.

The one change made outside version control: `agent_analytics` was created by hand in the running
ClickHouse. `CLICKHOUSE_DB` only takes effect on first-boot initialization, so an existing PVC
needs it once; a from-scratch run does not.

---

## Files changed

```
agents/common/audit.py                              CA bundle wired into the audit seam
agents/config/config.py                             KUID endpoint → aggregation layer
agents/provisioning/allocator/kuid.py               CA-bundle trust anchor, warns when absent
agents/tests/unit/test_kuid_client.py       (new)   6 tests for identity resolution
agents/tests/unit/test_us3_transport.py             allocator is token-bearing per T039
controllers/sonicprovider/controller.go             metric namespace hyphen → underscore
deploy/agentic-netops/manifests/provider.yaml       needs-apiserver label
deploy/agentic-netops/manifests/srv6-controller.yaml needs-apiserver label
deploy/agents/allocator.yaml                        automount token + needs-apiserver label
deploy/agents/namespace-rbac.yaml                   T050 repaired; ui-ingress; tier-intra-ingress
deploy/agents/secret-generator-job.yaml             bounded kubectl; needs-apiserver label
deploy/agents/telemetry.yaml                        CLICKHOUSE_DB=agent_analytics
deploy/observability/grafana-secret-generator-job.yaml  bounded kubectl
deploy/observability/otel-collector.yaml            needs-apiserver label
deploy/rbac/base.yaml                               allow-apiserver-egress
deploy/rbac/secret-generator-job.yaml               bounded kubectl; needs-apiserver label
scripts/install-deps.sh                             version-checked kubectl/kind
scripts/lib/intent_tier.sh                          build tier images when missing; fail loudly
```

Untracked and unrelated to this work: `agents/tests/unit/test_mapper_agent.py`, `ui/src/styles.css`.

Nothing has been committed.

---

## Verification commands

```bash
# UI
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30000/        # expect 200

# Intent tier
kubectl -n agentic-netops-agents get pods

# The NetworkPolicy allowance (from a pod that has the opt-in label)
kubectl -n agentic-netops-agents get networkpolicy

# KUID indices — vlan works, genid/extcomm do not
kubectl -n kuid-system get vlanindices,genidindices,extcommindices

# Fabric overlay divergence
for n in leaf01 leaf02; do
  docker exec clab-agentic-netops-fabric-$n ip -br link show type vxlan
done

# Unit tests
cd agents && uv run pytest tests/unit -q                                 # 118 passed
```

---

## Southbound closure (2026-09-04) — the loop now completes

The deployer's "inert southbound" is closed. `migr-bbae798efc224f7` (L3VPN) and
two fresh UI transactions (`migr-71f559ff546e419`, `migr-f1b10cf0d66245e`)
reconciled onto the fabric with `Ready=True`, verified per node.

**What was broken and how it was fixed (all found live, all in the tree now):**

1. **CRDs had no status subresource** — every status write 404'd silently, so
   the deployer's watch saw an empty status forever. All four kubenet CRDs now
   carry `subresources: {status: {}}` (source: `deploy/kubenet/crds/`).
2. **Pins read rode a poisoned informer** — the sdc.Config controller's
   cluster-scoped ConfigMap list is RBAC-denied, and any cache-backed read of
   `fabric-compat-pins` failed with it. `ResolveSitePins` now takes a minimal
   `compat.PinReader` and the reconcilers pass `mgr.GetAPIReader()` (uncached).
3. **Capability assertion** — "SRv6 not supported" was a *missing* capability
   label, not a real gap: versions.lock declares the image SRv6/gNMI-qualified
   and `scripts/lib/qualify.sh` gated it live ("[qualify] OK", sonic-srv6
   locator read-back asserted on both leaves). The CM now carries
   `cap-sai-srv6: "true"`, routed to `SitePins.Labels` (validator surface).
4. **fabric-executor runs on the host, not in the cluster** — kind nodes run
   containerd, so the host docker.sock cannot be mounted into a pod. The
   executor is a host service on `:8084` (`/var/local/agentic-netops/`,
   pidfile + log there), reached by provider pods at `http://172.30.0.1:8084`
   through an explicit netpol (ipBlock 172.30.0.1/32 tcp/8084) and an iptables
   INPUT rule for the kind bridge (`-i br-+ -p tcp --dport 8084 -j ACCEPT`,
   baked into provision.sh, idempotent).
5. **VRF names must match `^Vrf[a-zA-Z0-9_-]+$` AND be short** — sonic-vrf.yang
   rejected the deployer's 19-char `vrf-<hex>` names twice (length, then case).
   `fabricplan.DeviceVRFName` derives `Vrf-` + first 10 sanitized chars
   deterministically (≤14 total; exactly-16 still fails YANG — validated live).
6. **GCU read-back races vrfmgrd** — apply_patch can raise "still some parts
   not updated" when a daemon rewrites the table mid-transaction even though
   the write landed. The executor's GCU script now confirms the intended
   end-state directly against CONFIG_DB (sonic-db-cli, `TABLE|key` keys,
   depth-2/3 ops) before reporting failure.
7. **Redis ops are arguments, not shell commands** — plan Redis ops go through
   `redis-cli -n 4` now (bare `hset` exited 127).
8. **L3 attachment is bridge-access, not port-master** — enslaving the physical
   port to the VRF lets two services on one port fight over a single master
   (observed as flip-flopping ApplyFailed). The render now follows the
   bootstrap pattern: port → Bridge (vlan_filtering 1) as ACCESS in the service
   vlan; `Vlan<l3vlan>` bridge subdevice enslaved to the VRF, addressed from
   the intent's prefix; verify checks `bridge-vid` on the port (the awk had to
   handle indented rows — vid lands in $1 after the first line).
9. **vrfmgrd lag** — the kernel VRF device appears asynchronously after the
   GCU write; master-setting waits up to 10 s, verify stays strict.

**Honest rejections that must stay:** four migration-era Networks remain
`SchemaMismatch` (attachment references a vlan with no bridgeDomain; a port not
in the site map) — the validation gate is doing its job.


## Open decisions

1. **Fabric race (Pending #1)** — take it on, or leave the overlay non-forwarding for now?
2. **KUID (Pending #2)** — repin `kuid-server`, or move to the CRD-backed `id.kuid.dev` path?
3. **Ordering (Pending #3)** — should the tier install be independent of the fabric capability gate?
4. **From-scratch validation** — a full teardown-and-reprovision is the only way to actually prove
   the reproducibility claim. It takes the UI down for the duration.
