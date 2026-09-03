# AINETOPS lab tutorial

A walk-through of the SONiC EVPN/VXLAN fabric and the AGNTCY intent tier: bring it
up, look inside it, drive it from plain language, and tear it down.

Every command here was run against this lab. Where something does not work on the
pinned image, this says so rather than leaving you to find out.

---

## 0. Which tree do I use?

One repository, two working trees on two branches:

| Path | Branch | What it has |
| --- | --- | --- |
| `/root/ainetops-demo` | `main` | The fabric: `scripts/`, `lab/`, `controllers/`, `tests/`, `deploy/`. **Source of truth for fabric work.** |
| `/root/ainetops-002` | `002-agntcy-intent-tier` | Everything above **plus** `agents/` (the intent tier). **Source of truth for agent work.** |

They are not yet merged: `main` carries fabric fixes the 002 branch does not, and 002
carries the whole agent tier `main` does not. Use `main` for fabric-only work; use the
002 tree when you need the agents. See §6 before running the agent tier.

## 1. Prerequisites

Read **[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)** first. Two traps cost the most time:

- `provision.sh` dry-runs against your **current kubectl context**. Point it somewhere
  harmless or delete stale clusters first, or you get a confusing
  `namespaces "kubenet-system" not found`.
- `kubectl top` needs **metrics-server**, which kind does not install. Anything that
  measures resource usage silently returns nothing without it.

You need: Docker, kind, kubectl, containerlab, `gnmic`, and Go (the controllers are
built from vendored source). ~30–40 minutes for a first provision.

## 2. Bring the fabric up

```bash
cd /root/ainetops-demo
./scripts/provision.sh --profile sonic-vs --cluster-name ainetops
```

What that builds: a kind cluster running the SRv6Service controller and the kubenet
provider, plus a containerlab topology of **2 spines, 2 leaves, 4 clients** running
SONiC, wired as a Clos with a dual-stack eBGP underlay and an EVPN/VXLAN overlay.

Success looks like `exit 0` and:

```bash
docker ps --format '{{.Names}}' | grep clab-ainetops    # 8 containers
kubectl --context kind-ainetops get pods -A
```

## 3. Look inside the fabric

**Underlay BGP** — every node should be `Established`, v4 *and* v6:

```bash
docker exec clab-ainetops-fabric-leaf01 vtysh -c 'show bgp summary'
```

**EVPN control plane** — each leaf should list VNI 100 with a remote VTEP:

```bash
docker exec clab-ainetops-fabric-leaf01 vtysh -c 'show evpn vni'
#   VNI  Type  VxLAN IF    # MACs  # ARPs  # Remote VTEPs
#   100  L2    vtep1-100        2       0               1
```

`# Remote VTEPs = 1` is the signal that matters. It is non-zero only once the peer
leaf's IMET (Type-3) route has actually arrived **and** zebra installed it — it cannot
be faked by self-origination. Zero here means the overlay is dead no matter what else
looks healthy.

**Data path** — client-to-client across the VXLAN overlay:

```bash
docker exec clab-ainetops-fabric-client01 ping -c3 192.0.2.21
```

**Dual-stack underlay** — loopback reachability leaf to leaf:

```bash
docker exec clab-ainetops-fabric-leaf01 ping -6 -c3 2001:db8:ff::22
```

**Configuration over gNMI** — the fabric is readable through SONiC's gNMI server:

```bash
U=$(kubectl --context kind-ainetops -n ainetops-system get secret gnmi-lab-creds \
      -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl --context kind-ainetops -n ainetops-system get secret gnmi-lab-creds \
      -o jsonpath='{.data.password}' | base64 -d)
gnmic --address 172.31.0.11:8080 --username "$U" --password "$P" \
      --tls-ca ./secrets/ca.crt --tls-cert ./secrets/gnmi.crt --tls-key ./secrets/gnmi.key \
      get --path "/sonic-db:CONFIG_DB/BGP_NEIGHBOR"
```

Credentials are generated per provision and stored in the `gnmi-lab-creds` secret —
never hard-code `admin/admin`.

## 4. Run the test suites

```bash
./tests/integration/fabric_verify.sh run   # BGP, EVPN routes, overlay data path, FR-004
make verify-pins                           # every image/binary matches versions.lock.yaml
make denylist                              # vendor-neutrality checks
```

`fabric_verify.sh` fails closed by design: an assertion that cannot be *proved* fails
rather than passing quietly. A gNMI query that errors is reported `QUERY_FAILED`, never
read as "absent".

## 5. Tear down

```bash
./scripts/off.sh --delete-kind true    # idempotent; safe to re-run
```

---

## 6. The AGNTCY intent tier

The agent tier turns a plain-language service request into declarative Kubernetes
resources. It lives on the **002 branch**, so run it from that tree:

```bash
cd /root/ainetops-002
./scripts/provision.sh --profile sonic-vs --cluster-name ainetops --with-intent-tier
```

> **Before you do:** the 002 branch does not yet carry `main`'s fabric fixes (VTEP
> bridging, IPv6 forwarding, the access-link join). Merge `main` into it first, or the
> fabric underneath the agents will be the broken version.

### What gets deployed

Into namespace `ainetops-agents`, in this order:

| Component | Role |
| --- | --- |
| `slim` | The SLIM message bus carrying A2A between agents |
| `supervisor` | Conversational LangGraph state machine; classifies and orchestrates |
| `mapper` | Natural language → schema-validated `Interpretation` |
| `allocator` | KUID `Claim` + `NormalizedServiceIntent` contract |
| `deployer` | Translator client + submission to the cluster |
| `ui` | Chat front-end, NodePort **30000** |

### Talking to the agents

**Through the UI** — open <http://localhost:30000>. The kind cluster maps container
port 30000 to host 30000 (`config/kind/cluster.yaml`).

**Through the cluster** — watch the tier work:

```bash
kubectl --context kind-ainetops -n ainetops-agents get pods
kubectl --context kind-ainetops -n ainetops-agents logs -f deploy/supervisor
```

**What to ask it.** The supervisor classifies every request into one of three classes,
so try one of each:

- *provisionable* — "Create an L2 service for tenant blue between leaf01 port eth3 and
  leaf02 port eth3." It should produce an `Interpretation`, claim identifiers, and
  submit an `SRv6Service`.
- *informational* — "What service types do you support?" Answered directly, nothing
  provisioned.
- *unsupported* — a request for something outside the declarative model. It should
  refuse and name the supported equivalent rather than improvise.

**Watch the result land on the fabric:**

```bash
kubectl --context kind-ainetops get srv6services -A
docker exec clab-ainetops-fabric-leaf01 vtysh -c 'show evpn vni'
```

The tier has **no device sessions and cannot acquire one** (FR-016/FR-029). It only
ever writes Kubernetes resources; the controllers do the southbound work. That
separation is deliberate — feature 001 replaced a proprietary southbound with an open
Kubernetes-native one, and 002 restores only the northbound intent layer.

### The supervisor needs an LLM

`LLM_MODEL` is empty in the committed manifest and materialized at provision time — the
provider is chosen by the `LLM_MODEL` prefix alone, and no key is ever committed. With
no model configured the tier deploys but cannot reason.

---

## 7. Known limitations

Real, reproduced, and documented rather than hidden:

- **EVPN Type-5 routes are not originated.** The pinned `sonic-vs` FRR 10.5.4 build
  drops the `vni` line from the VRF stanza and never adopts the L3VNI. Type-2 and
  Type-3 work, including the bridged data path. Set
  `AINETOPS_WAIVE_TYPE5_ORIGINATION=1` to continue past the assertion with the gap
  recorded. See `docs/FABRIC_BGP_EVPN_DEFERRED.md` D-A2.
- **`vlanmgrd` can crash on startup** (AddressSanitizer), leaving a leaf with no
  overlay devices. Provisioning fails closed. `AINETOPS_WAIVE_L2VNI_ADOPTION=1`
  continues with the defect reported — D-A3.
- **SRv6 conformance (SC-013/SC-014) needs the `sonic-vm` profile**, which requires an
  operator-built vrnetlab image *and* a `lab/profiles/sonic-vm/bootstrap/` directory
  that does not exist yet. The `sonic-vs` profile cannot satisfy those criteria.
- **Two pinned images have no local build step** (`grafana/flow-plugin`,
  `ghcr.io/ainetops/topology-generator`); the dependent workload ends in
  `ImagePullBackOff`. `deployment/ui` is the observed case.
- **`docs/INTENT_TIER_OPS_READINESS.md` contains resource figures that were never
  measured.** Re-measure before relying on them.

## 8. Troubleshooting

| Symptom | Cause | Check |
| --- | --- | --- |
| Overlay ping 100% loss, BGP healthy | `vtep1-100` not enslaved to Bridge, so bgpd has 0 L2 VNIs | `ip -d link show vtep1-100 \| grep master` |
| `show evpn vni` empty on one leaf | zebra started before the vxlan devices existed | restart `zebra` then `bgpd` |
| Leaf→leaf IPv6 fails, leaf→spine works | IPv6 forwarding off on the transit node | `sysctl net.ipv6.conf.all.forwarding` |
| gNMI `Unauthenticated` | creds rotated by a re-provision | re-read the `gnmi-lab-creds` secret |
| `namespaces "kubenet-system" not found` | wrong kubectl context | `kubectl config current-context` |

A provision log that ends in a bash syntax error on a valid line usually means the
script was edited *while running* — bash reads scripts by byte offset. Compare the
script's mtime against the failure timestamp before believing the code is wrong.
