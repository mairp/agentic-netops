# agentic-netops - Autonomous intent-to-fabric operations.

This lab demonstrates a network that **runs itself**: you state intent in plain
language, and the system decomposes it, allocates identifiers, programs the fabric,
and then *keeps* it that way — repairing drift, surviving failures, and releasing
resources when intent is withdrawn. No one logs into a switch.

The fabric is Nokia SR Linux, and the southbound is gNMI end to end: every write
is a gNMI Set, every verification a gNMI Get, every metric a gNMI subscription.

The interesting question is not "can it configure a VLAN". It is **what happens after**
— when something changes underneath it, when a component dies mid-transaction, when
the same intent is applied twice. Those are the sections that matter here.

---

## The loop

```
   plain language          ┌──────────────┐
   "connect tenant  ──────►│  supervisor  │  classify: provisionable?
    blue, leaf01↔02"       └──────┬───────┘
                                  │ A2A over SLIM
                    ┌─────────────┼─────────────┐
                    ▼             ▼             ▼
                 mapper       allocator      deployer
              interpret     claim IDs      submit CR
                    └─────────────┼─────────────┘
                                  ▼
                        ┌──────────────────┐
                        │   Network (CR)   │   declarative desired state
                        └────────┬─────────┘
                                 ▼
                        ┌──────────────────┐
                        │   controllers    │◄─── reconcile loop, forever
                        └────────┬─────────┘
                                 ▼
                     SR Linux fabric (gNMI Set/Get)
                                 │
                                 └──► telemetry ──► back to the top
```

The agents run **once per request**. The controllers run **continuously** — that is
where autonomy actually lives.

## 1. Bring it up

```bash
cd /root/agentic-netops-srlinux
./scripts/provision.sh --profile srlinux --cluster-name agentic-netops --with-intent-tier
```

Read **[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)** first — two traps cost the most
time: `provision.sh` dry-runs against your **current kubectl context**, and `kubectl
top` silently returns nothing without metrics-server, which kind does not install.

The underlay and overlay are not scripted into place after boot: each node comes up
with its own startup configuration (`lab/profiles/srlinux/config/<node>.cfg`, applied
by containerlab), so the eBGP underlay, the iBGP EVPN overlay with the spines as route
reflectors, and the bootstrap `vlan100` mac-vrf and `VrfBlue` ip-vrf on the leaves are
part of the device's configuration from the first second. There are no post-boot shell
hooks and nothing to re-toggle: SR Linux commits configuration transactionally and
keeps it across a container restart. The bootstrap step that *does* run is small and
declared — it waits for gNMI Capabilities on each node, creates the generated
`agentic` user over one gNMI Set, and publishes the containerlab CA into the
`gnmi-lab-tls` Secret.

Watch it happen:

```bash
grep -E '\[bootstrap\]|\[qualify\]' provision.log
make lab-qualify        # ends in [qualify] OK, or names the failing check
```

The gate fails **closed**: a check it cannot prove fails rather than passing quietly,
and SRv6 entries are recorded as `not-applicable` with the reason (the SR Linux
container has no SRv6 data plane) — never as `pass`.

## 2. State intent

Walk one of each construct. These are the shapes the tier accepts — vlan, mac-vrf, ip-vrf and acl — and both ACL shapes (standalone and attached):

- vlan: "Provision a vlan 120 on leaf01 ethernet1 for tenant acme"
- mac-vrf: "Extend vlan 100 as a mac-vrf across leaf01 ethernet2 and leaf02 ethernet2 for tenant blue"
- ip-vrf: "Give tenant initech an ip-vrf carrying 10.50.0.0/24 on leaf01 wan1"
- acl (standalone): "Apply an acl on leaf01 ethernet1 and leaf02 ethernet1 for tenant acme: permit tcp 443 from 10.0.0.0/24, deny everything else"
- mac-vrf + acl: "Extend vlan 130 as a mac-vrf across leaf01 ethernet2 and leaf02 ethernet2 for tenant acme, permitting only tcp 443 from 10.0.0.0/24"

The logical port names are the site's own (`ethernet1`, `ethernet2`, `ethernet3`,
`wan1`); the provider maps them to the SR Linux interfaces `ethernet-1/3` and
`ethernet-1/4`, and each service gets its own single-tagged subinterface on that
interface.

Open the chat UI at <http://localhost:30000>, or watch the tier reason:

```bash
kubectl --context kind-agentic-netops -n agentic-netops-agents logs -f deploy/supervisor
```

The supervisor classifies every request before acting. Try one of each class:

| Say | Class | Expected behaviour |
| --- | --- | --- |
| "Extend vlan 100 as a mac-vrf across leaf01 ethernet2 and leaf02 ethernet2 for tenant blue" | provisionable | interprets → claims IDs → submits a `Network` |
| "What service types do you support?" | informational | answers; provisions nothing |
| something outside the declarative model | unsupported | refuses, names the supported equivalent |

That third row is the point: an autonomous system that cannot say *no* is not safe to
run unattended. It refuses rather than improvising.

Say the request, then `confirm` twice — the graph provisions only after two
explicit confirmations, so a one-shot request stops at its iteration bound by
design. Name a node or port the site does not have and the translator refuses it
before anything is submitted, listing the real ones.

Watch desired state appear, then reality follow it:

```bash
# what the tier submitted, and the controller's own verdict on it
kubectl --context kind-agentic-netops -n agentic-netops-intent get networks.network.kubenet.dev \
  -o custom-columns=NAME:.metadata.name,\
TYPE:'.metadata.annotations.agentic-netops\.io/service-type',\
READY:'.status.conditions[?(@.type=="Ready")].status' -w

# and on the device itself, read-only
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance summary"
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance vlan-120 interfaces"
```

`Ready=True` is set only after every rendered gNMI Set applied *and* every
per-node gNMI Get check passed, and it is re-verified every five minutes — so it
describes the fabric now, not the moment the service first converged.

For a mac-vrf, the signal that matters is the **remote VTEP**:

```bash
docker exec clab-agentic-netops-fabric-leaf01 \
  sr_cli "show tunnel-interface vxlan1 vxlan-interface 10001 bridge-table multicast-destinations"
```

A non-empty multicast-destinations list exists only once the peer leaf's IMET route
actually arrived and was installed. It cannot be faked by self-origination — which is
exactly why the plan asserts it with a `gnmi-list-min >= 1` check rather than reading
back the object the controller just wrote.

For an ip-vrf, the equivalent is the Type-5 route on the *other* leaf:

```bash
docker exec clab-agentic-netops-fabric-leaf02 \
  sr_cli "show network-instance default protocols bgp routes evpn route-type 5 summary"
```

## 3. Prove it is autonomous

Anything can apply config once. These four properties are what make it *autonomous*,
and each has a test you can run.

### 3.1 It repairs drift

Change the fabric out from under the controller — the thing a human "just fixing
something quickly" would do — and watch it be undone:

```bash
./tests/integration/drift_preservation.sh
```

Managed paths are **restored**; unmanaged paths are **preserved**. That distinction is
the whole design: the controller owns what it declared and deliberately does not touch
anything else, so it can run continuously without trampling local state.

### 3.2 It survives failure mid-flight

```bash
./tests/integration/failure_recovery_invalid_yang.sh
```

Kills a target mid-transaction and restarts the provider *while it is writing*. The
system converges anyway, and a Set the node's YANG rejects is refused whole — SR Linux
commits a Set as one transaction, so there is no half-applied state to clean up, and
the node's own error text is what lands in `Ready=False/ApplyFailed`.

### 3.3 It does not churn

```bash
./tests/integration/idempotence.sh
```

Re-applying unchanged intent produces **zero** SDC spec writes and **zero** gNMI Sets.
A reconcile loop that rewrites on every pass is not stable — it is a flap generator.

### 3.4 It releases what it claimed

```bash
./tests/integration/update_delete_survivability.sh
```

Withdraw intent and the service's identifier claims are released and its device
objects deleted in reverse order, while shared fabric state and unrelated claims
survive untouched. The rollback never deletes an object the service did not create.

### Run the whole thing

```bash
make lab-qualify                           # gNMI Capabilities/Get/Set/Subscribe, persistence, EVPN
./tests/integration/fabric_verify.sh run   # control plane + data path, fails closed
make verify-pins                           # every image/binary matches versions.lock.yaml
```

`fabric_verify.sh` fails closed by design: an assertion it cannot *prove* fails rather
than passing quietly. A gNMI query that errors is `QUERY_FAILED`, never read as
"absent" — the difference between "the spine has no tenant state" and "I could not ask
the spine".

## 4. Tear down

```bash
./scripts/off.sh --delete-kind true    # idempotent; safe to re-run
```

---

## Appendix — looking under the hood

You do not need any of this to run the demo. It is here for when you want to confirm
what the system did, or to debug it.

```bash
# underlay and overlay: every session Established, v4 and v6
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance default protocols bgp neighbor"

# what tenant state this leaf carries
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance summary"

# overlay data path, client to client across VXLAN
docker exec clab-agentic-netops-fabric-client01 ping -c3 192.0.2.21

# dual-stack underlay, leaf to leaf loopback
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "ping 2001:db8:ff::22 network-instance default"

# read state over gNMI with the per-provision generated credentials
U=$(kubectl --context kind-agentic-netops -n agentic-netops-system get secret gnmi-lab-creds \
      -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl --context kind-agentic-netops -n agentic-netops-system get secret gnmi-lab-creds \
      -o jsonpath='{.data.password}' | base64 -d)
gnmic --address 172.31.0.21:57400 --username "$U" --password "$P" \
      --tls-ca ./secrets/ca.crt --encoding json_ietf \
      get --path "/network-instance[name=default]/protocols/bgp/neighbor"
```

The SR Linux gNMI server authenticates with username and password over TLS and does
not require a client certificate; only the containerlab CA is needed to trust it.
Credentials are generated per provision — never hard-code the image default.

## What the tier deliberately cannot do

The intent tier holds **no device sessions and cannot acquire one**. It
only ever writes Kubernetes resources; controllers do all southbound work.
An agent that could reach a device directly would
bypass every reconcile guarantee above. The NetworkPolicy on the tier namespace
excludes the management subnet `172.31.0.0/16` from every egress rule, and
`deploy/agents/tests/probes/mgmt-network-denial.sh` attempts the connection to
`172.31.0.21:57400` and asserts that it fails.

`LLM_MODEL` is empty in the committed manifest and materialized at provision time from
`.env` (copy `.env.example`) — the provider is chosen by the `LLM_MODEL` prefix alone,
and no key is ever committed. With no model configured the tier deploys but cannot reason.

## Known limitations

Declared rather than hidden:

- **This fabric has not been brought up from this tree yet.** The SR Linux target is
  the offline work of Phases 1–3 of
  [the plan](specs/001-agentic-netops-srlinux-evpn-fabric/plan.md); bring-up, the four
  constructs converging and the recorded walkthrough are Phases 4–6 and run on the
  operator's host. Every command above is written against the contracts in
  `specs/001-agentic-netops-srlinux-evpn-fabric/contracts/`; anything marked
  *verify live* in `research.md` has not yet been read back off a running node.
- **SRv6 is not applicable on this target.** The SR Linux container has no SRv6 data
  plane. `SRv6Service` objects report `Ready=False` with reason `CapabilityMissing`,
  the capability gate records SRv6 as `not-applicable` with that reason, and the SRv6
  dashboard says so instead of charting an empty series.
- **An acl-only service binds on subinterface index 0.** SR Linux binds ACL filters to
  subinterfaces, not to ports, so a `Network` that declares only an access list binds
  its filter on index 0 of the named interface, creating it as `type routed` in the
  `default` network-instance if absent.
- **Two pinned images have no local build step** (`grafana/flow-plugin`,
  `ghcr.io/agentic-netops/topology-generator`); the dependent workload ends in
  `ImagePullBackOff`.
- **`docs/INTENT_TIER_OPS_READINESS.md` holds resource figures that were never
  measured.** Re-measure before relying on them.

## Troubleshooting

| Symptom | Cause | Check |
| --- | --- | --- |
| mac-vrf up on both leaves but no remote VTEP | the peer's IMET route has not arrived (overlay session not Established, or evi mismatch) | `sr_cli "show network-instance <ni> protocols bgp-evpn"` and `sr_cli "show network-instance default protocols bgp neighbor"` |
| ip-vrf Ready but no Type-5 on the peer | export/import route-target mismatch, or the prefix is not in the vrf's route table | `sr_cli "show network-instance <vrf> route-table ipv4-unicast summary"` |
| gNMI `Unauthenticated` | credentials rotated by a re-provision | re-read the `gnmi-lab-creds` Secret |
| gNMI TLS handshake failure | the lab CA changed with a new `containerlab deploy` | re-run bootstrap so `gnmi-lab-tls` and `./secrets/ca.crt` are republished |
| Subinterface admin-up but oper-down | the parent interface is missing `vlan-tagging true`, or the encap tag collides | `sr_cli "show interface ethernet-1/3 detail"` |
| `namespaces "kubenet-system" not found` | wrong kubectl context | `kubectl config current-context` |

A provision log ending in a bash syntax error on a valid line usually means the script
was edited *while running* — bash reads scripts by byte offset. Compare the script's
mtime against the failure timestamp before believing the code is wrong.
