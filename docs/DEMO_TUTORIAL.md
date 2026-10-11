# agentic-netops demo tutorial — building blocks, services, and identifiers

A step-by-step companion to [TUTORIAL.md](../TUTORIAL.md) focused on the four
building blocks — **SDC (sdcio)**, **Kubenet**, **KUID**, **SRv6** — the services
you can provision live, and how to retrieve object UUIDs and allocated identifiers
from Kubernetes. For the call-planning view see
[DEMO_STRATEGY_WEBEX.md](DEMO_STRATEGY_WEBEX.md).

> Naming note: "kuuid" in the project is **KUID** (`id.kuid.dev`), the
> index/claim allocator, deployed alongside **Kubenet** (`network.kubenet.dev`).

---

## 0. Bring the lab up

```bash
cd /root/agentic-netops
cp .env.example .env          # set LLM_MODEL — without it the tier deploys but cannot reason
./scripts/provision.sh --profile sonic-vs --cluster-name agentic-netops --with-intent-tier
export CTX=--context kind-agentic-netops
```

> **Paste-safety tip:** every command below is a single line on purpose. When
> pasting multi-line commands from notes or slides, a broken `\` continuation
> makes kubectl read the column spec as an object *name* — the tell-tale error is
> `Error from server (NotFound): ... "custom-columns=..." not found`. If you see
> it, re-run the line as one; also confirm `echo $CTX` prints
> `--context kind-agentic-netops`.

Confirm the three stacks are installed:

```bash
kubectl $CTX get crd | grep -E 'kubenet|kuid|sdcio'
# networks.network.kubenet.dev   srv6services.agentic-netops.io
# ipindexes.id.kuid.dev  asnindexes.id.kuid.dev  vniindexes.id.kuid.dev  claims.id.kuid.dev
# configs.sdc.sdcio.dev  targets.sdc.sdcio.dev   schemas.sdc.sdcio.dev   ...
```

Fabric sanity: two spines, two leaves, four clients in containerlab
(`docker ps | grep clab-agentic-netops`), underlay established:

```bash
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show bgp summary'
```

---

## 1. Building block: SDC / sdcio (model-driven config plane)

SDC runs in-cluster (Schema server, Config server, Data server, Cache; manifests in
`deploy/sdc/`). It is the only path to the devices: controllers write Config
resources, SDC renders them against the SONiC YANG schema and applies over gNMI.

```bash
# the fabric nodes as SDC targets, and their sync state
kubectl $CTX get targets.sdc.sdcio.dev -A

# desired config per service, held declaratively
kubectl $CTX get configs.sdc.sdcio.dev -A

# schemas loaded for SONiC
kubectl $CTX get schemas.sdc.sdcio.dev -A
```

What to say: agents never open a device session — they only write Kubernetes
resources. SDC is where "declarative" becomes bytes on the box, and because every
apply is a reconcile of desired state, re-applying unchanged intent produces **zero**
writes:

```bash
./tests/integration/idempotence.sh   # asserts no SDC spec writes, no gNMI Sets
```

---

## 2. Building block: Kubenet (service intent, `network.kubenet.dev`)

Kubenet provides the topology and network-service model. This repo deploys a
`Topology` (the 2×2 Clos), and adds the `Network` CR (service types: vlan,
mac-vrf, ip-vrf, acl) plus the `SRv6Service` CR.

```bash
kubectl $CTX -n kubenet-system get topology
kubectl $CTX -n agentic-netops-intent get networks.network.kubenet.dev

# watch desired state and the controller's verdict, live
kubectl $CTX -n agentic-netops-intent get networks.network.kubenet.dev -o 'custom-columns=NAME:.metadata.name,TYPE:.metadata.annotations.agentic-netops\.io/service-type,READY:.status.conditions[?(@.type=="Ready")].status' -w
```

`Ready=True` is written only after every rendered operation applied **and** every
per-node verification passed — and it is re-verified every five minutes.

---

## 3. Building block: KUID (identifier allocation, `id.kuid.dev`)

KUID models scarce identifiers as indexes; consumers file `Claim`s. The lab ships
IP/ASN/VNI pools for the fabric plus a dedicated SRv6 chain:

```bash
kubectl $CTX -n kuid-system get ipindexes,asnindexes,vniindexes
# srv6-locator-v6  2001:db8:feed::/48      <- locator pool
# srv6-sids-v6     2001:db8:feed:100::/64  <- SID pool under it
# srv6-service-ids VNI range 500000-500999 <- SRv6 service IDs
```

Provisioning a service makes a claim appear; withdrawing intent releases it —
shared fabric state and unrelated claims survive:

```bash
kubectl $CTX -n kuid-system get claims -o wide
./tests/integration/update_delete_survivability.sh   # proves claim release
```

---

## 4. Building block: SRv6

`SRv6Service` expresses a bidirectional IPv6 VPN: a KUID-allocated locator, two
attachments, a path with primary/alternate waypoints, and an immutable VRF.
Structural CEL rules on the CRD reject bad shapes (non-IPv6 prefixes, identical
endpoints, locator outside /48-/64) at admission time.

Try it directly:

```bash
kubectl $CTX -n agentic-netops-intent apply -f - <<'EOF'
apiVersion: agentic-netops.io/v1alpha1
kind: SRv6Service
metadata:
  name: demo-srv6
spec:
  topologyRef: agentic-netops-topology
  vrf: demo-vrf
  underlay: ipv6
  locatorPrefix: 2001:db8:feed::/48
  servicePrefix: 2001:db8:10::/64
  path:
    primary: spine01
  attachments:
  - node: leaf01
    interface: ethernet4
  - node: leaf02
    interface: ethernet4
  client:
    name: srv6-client01
    ip: 2001:db8:10::11/64
  server:
    name: srv6-client02
    ip: 2001:db8:10::22/64
EOF
kubectl $CTX -n agentic-netops-intent get srv6services demo-srv6 -w
```

Verify on the fabric:

```bash
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show segment-routing srv6 locator'
```

Honest limitations to state: full SRv6 conformance runs on the `sonic-vm` profile;
on the virtual-SONiC image the proven path is GCU-write → gNMI read-back witnesses
(locator, `SRV6_MY_SIDS`, counters) — details in
[SRV6_GNMI_CAPABILITY_FINDINGS.md](SRV6_GNMI_CAPABILITY_FINDINGS.md).

---

## 5. Provision services from plain language

Open the console at http://localhost:30000 (the scenario cards are exactly what the
supervisor advertises on `GET /suggested-prompts`), say the prompt, `confirm` twice.

| Prompt | Construct |
|--------|-----------|
| "Provision a vlan 120 on leaf01 ethernet1 for tenant acme" | vlan |
| "Extend vlan 100 as a mac-vrf across leaf01 ethernet2 and leaf02 ethernet2 for tenant blue" | mac-vrf |
| "Give tenant initech an ip-vrf carrying 10.50.0.0/24 on leaf01 wan1" | ip-vrf |
| "Apply an acl on leaf01 ethernet1 and leaf02 ethernet1 for tenant acme: permit tcp 443 from 10.0.0.0/24, deny everything else" | acl |

Watch the tier reason:

```bash
kubectl $CTX -n agentic-netops-agents logs -f deploy/supervisor
```

Prove each one where it counts:

```bash
# vlan: CONFIG_DB on the leaf
docker exec clab-agentic-netops-fabric-leaf01 docker exec sonic /usr/local/bin/sonic-cfggen -d --print-data | grep -A3 VLAN

# mac-vrf: EVPN overlay on BOTH leaves — Remote VTEPs = 1 is the signal that matters
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show evpn vni'
docker exec clab-agentic-netops-fabric-leaf02 vtysh -c 'show evpn vni'

# end-to-end data path
docker exec clab-agentic-netops-fabric-client01 ping -c3 192.0.2.21
```

Also demo the refusal: name a port that does not exist ("leaf01 ethernet99"). The
translator refuses **before** submission and lists the site's real ports. And the
informational class: "What service types do you support?" answers, provisions
nothing.

---

## 6. Retrieving UUIDs and identifiers from Kubernetes

Three layers, each answering a different audit question.

### 6.1 Kubernetes object UUIDs — *which object is this?*

Every CR carries an immutable etcd-level `metadata.uid`:

```bash
# all Networks with their UUIDs
kubectl $CTX -n agentic-netops-intent get networks.network.kubenet.dev -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,CREATED:.metadata.creationTimestamp'

# SRv6Services as name<TAB>uid
kubectl $CTX -n agentic-netops-intent get srv6services -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{.metadata.uid}{"\n"}{end}'

# one object, full metadata including uid
kubectl $CTX -n agentic-netops-intent get network <name> -o jsonpath='{.metadata.uid}'
```

### 6.2 Correlation IDs — *which sentence created it?*

The console stamps each request with a `correlation_id`, carried on the Network as
a label — the thread from chat to CR to events:

```bash
kubectl $CTX -n agentic-netops-intent get networks -l agentic-netops.io/correlation-id=<id-shown-in-the-console> -o 'custom-columns=NAME:.metadata.name,TYPE:.metadata.annotations.agentic-netops\.io/service-type,READY:.status.conditions[?(@.type=="Ready")].status,REASON:.status.conditions[?(@.type=="Ready")].reason'

# the controller's own verdict as events
kubectl $CTX -n agentic-netops-intent get events --field-selector reason=ApplySucceeded
```

A worked example of the whole chain (prompt → correlation id → Ready condition →
fabric evidence) is captured in
[media/agentic-netops-intent-tier-demo-evidence.json](media/agentic-netops-intent-tier-demo-evidence.json).

### 6.3 KUID claims — *which fabric identifiers did it consume?*

Not Kubernetes UUIDs — the actual network identity allocated to each service:

```bash
kubectl $CTX -n kuid-system get claims -o 'custom-columns=NAME:.metadata.name,POOL:.spec.from.name,PURPOSE:.spec.purpose'
```

Together the three layers give a complete audit chain: `metadata.uid` proves which
object you are auditing, the correlation-id proves which intent created it, and the
KUID claim proves which VNI/locator/SID it consumed.

---

## 7. Prove autonomy (optional, ~10 min)

```bash
./tests/integration/drift_preservation.sh            # managed paths restored, unmanaged preserved
./tests/integration/failure_recovery_invalid_yang.sh # target killed mid-write still converges
./tests/integration/idempotence.sh                   # no churn
./tests/integration/update_delete_survivability.sh   # claims released, shared state intact
./tests/integration/fabric_verify.sh run             # fails closed, never "green by assumption"
```

## 8. Tear down

```bash
./scripts/off.sh --delete-kind true   # idempotent; safe to re-run
```

## Troubleshooting quick hits

| Symptom | Fix |
|---------|-----|
| `kubectl top` returns nothing | kind has no metrics-server — expected |
| gNMI `Unauthenticated` | credentials rotate per provision — re-read the `gnmi-lab-creds` secret (TUTORIAL.md appendix) |
| `namespaces "kubenet-system" not found` | wrong kubectl context — check `$CTX` |
| Console up but no reasoning | `LLM_MODEL` empty in `.env` |
| Provision dry-run hits the wrong cluster | `provision.sh` uses your *current* context — set it first |
