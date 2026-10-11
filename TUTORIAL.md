# agentic-netops - Autonomous intent-to-fabric operations.

This lab demonstrates a network that **runs itself**: you state intent in plain
language, and the system decomposes it, allocates identifiers, programs the fabric,
and then *keeps* it that way — repairing drift, surviving failures, and releasing
resources when intent is withdrawn. No one logs into a switch.

The interesting question is not "can it configure a VLAN". It is **what happens after**
— when something changes underneath it, when a component dies mid-transaction, when
the same intent is applied twice. Those are the sections that matter here.

---

## The loop

> Preparing to present this lab? See [docs/DEMO_STRATEGY_WEBEX.md](docs/DEMO_STRATEGY_WEBEX.md)
> (run of show, building-blocks narrative, lessons learned) and
> [docs/DEMO_TUTORIAL.md](docs/DEMO_TUTORIAL.md) (hands-on steps for SDC/Kubenet/KUID/SRv6,
> services, and UUID/identifier retrieval).

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
                        │  SRv6Service CR  │   declarative desired state
                        └────────┬─────────┘
                                 ▼
                        ┌──────────────────┐
                        │   controllers    │◄─── reconcile loop, forever
                        └────────┬─────────┘
                                 ▼
                          SONiC fabric (gNMI)
                                 │
                                 └──► telemetry ──► back to the top
```

The agents run **once per request**. The controllers run **continuously** — that is
where autonomy actually lives.

## 1. Bring it up

```bash
cd /root/agentic-netops
./scripts/provision.sh --profile sonic-vs --cluster-name agentic-netops --with-intent-tier
```

Read **[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)** first — two traps cost the most
time: `provision.sh` dry-runs against your **current kubectl context**, and `kubectl
top` silently returns nothing without metrics-server, which kind does not install.

The bootstrap is itself autonomous: it detects and repairs its own faults rather than
failing and waiting for a human. It waits for `Bridge` before enslaving interfaces,
re-toggles `advertise-all-vni` when bgpd loses the VNI, escalates to restarting zebra
when zebra's own table is empty, and fails **closed** with a named defect when it
genuinely cannot converge. Watch it say so:

```bash
grep -E '\[fabric-bgp\]' provision.log
#   [fabric-bgp] L2 VTEP vtep1-100 bridged into vlan 100
#   [fabric-bgp] access link eth3 bridged into vlan 100
#   [fabric-bgp] leaf01: bgpd adopted L2 VNI 100 after advertise-all-vni toggle (no restart needed)
```

## 2. State intent

Walk one of each construct. These are the shapes the tier accepts — vlan, mac-vrf, ip-vrf and acl — and both ACL shapes (standalone and attached):

- vlan: "Provision a vlan 120 on leaf01 ethernet1 for tenant acme"
- mac-vrf: "Extend vlan 100 as a mac-vrf across leaf01 ethernet2 and leaf02 ethernet2 for tenant blue"
- ip-vrf: "Give tenant initech an ip-vrf carrying 10.50.0.0/24 on leaf01 wan1"
- acl (standalone): "Apply an acl on leaf01 ethernet1 and leaf02 ethernet1 for tenant acme: permit tcp 443 from 10.0.0.0/24, deny everything else"
- mac-vrf + acl: "Extend vlan 130 as a mac-vrf across leaf01 ethernet2 and leaf02 ethernet2 for tenant acme, permitting only tcp 443 from 10.0.0.0/24"


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

docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show evpn vni'
```

`Ready=True` is set only after every rendered operation applied *and* every
per-node check passed, and it is re-verified every five minutes — so it
describes the fabric now, not the moment the service first converged.

`# Remote VTEPs = 1` is the signal that matters — it is non-zero only once the peer
leaf's IMET route actually arrived **and** zebra installed it. It cannot be faked by
self-origination.

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
system converges anyway, and invalid YANG is rejected rather than half-applied.

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

Withdraw intent and the SRv6-owned identifier claims are released, while shared fabric
state and unrelated claims survive untouched.

### Run the whole thing

```bash
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
# underlay: every node Established, v4 and v6
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show bgp summary'

# overlay data path, client to client across VXLAN
docker exec clab-agentic-netops-fabric-client01 ping -c3 192.0.2.21

# dual-stack underlay, leaf to leaf
docker exec clab-agentic-netops-fabric-leaf01 ping -6 -c3 2001:db8:ff::22

# read config over gNMI with the per-provision generated credentials
U=$(kubectl --context kind-agentic-netops -n agentic-netops-system get secret gnmi-lab-creds \
      -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl --context kind-agentic-netops -n agentic-netops-system get secret gnmi-lab-creds \
      -o jsonpath='{.data.password}' | base64 -d)
gnmic --address 172.31.0.11:8080 --username "$U" --password "$P" \
      --tls-ca ./secrets/ca.crt --tls-cert ./secrets/gnmi.crt --tls-key ./secrets/gnmi.key \
      get --path "/sonic-db:CONFIG_DB/BGP_NEIGHBOR"
```

Credentials are generated per provision — never hard-code `admin/admin`.

## What the tier deliberately cannot do

The intent tier holds **no device sessions and cannot acquire one**. It
only ever writes Kubernetes resources; controllers do all southbound work.
An agent that could reach a device directly would
bypass every reconcile guarantee above.

`LLM_MODEL` is empty in the committed manifest and materialized at provision time from
`.env` (copy `.env.example`) — the provider is chosen by the `LLM_MODEL` prefix alone,
and no key is ever committed. With no model configured the tier deploys but cannot reason.

## Known limitations

Real, reproduced, documented rather than hidden:

- The former SONiC ASan/L2-VNI and EVPN Type-5 gaps (D-A2/D-A3) are resolved
  on the pinned `sonic-vs-gnmi:202505-v1` image and their waivers are retired.
- **SRv6 conformance runs on the `sonic-vm` profile**, which is now fully
  wired AND qualified: `lab/profiles/sonic-vm/bootstrap/` (VM-aware,
  SSH-driven gNMI/TLS provisioning) and `lab/topology.sonic-vm.clab.yml`
  exist, `scripts/build-sonic-vm.sh` builds the vrnetlab image, and the full
  qualification gate (`scripts/lib/qualify.sh`: Capabilities/Get/Set/
  Subscribe, sonic-srv6, persistence, EVPN Type-2/3/5, SRv6 underlay/End/
  End.DT46/decap/counters, YANG paths) passes end-to-end against
  `local/sonic-vm:202505`. It still requires the **operator** to build the
  `local/sonic-vm` image
  (`scripts/build-sonic-vm.sh --image-url <sonic-vs.img.gz> --update-pin`),
  because no public registry serves it, plus KVM/nested virtualization on the
  host. Until that build exists on your host, `--profile sonic-vm` fails at
  deploy with a missing-image error (the documented gate-fail path).
  sonic-vm-profile notes (all verified on the pinned image):
  - gNMI TLS is driven by the **`GNMI` CONFIG_DB table** (`GNMI|gnmi` +
    `GNMI|certs`), not the legacy `TELEMETRY` table — `gnmi-native.sh`
    renders `telemetry_vars.j2` against `GNMI`, and an undefined table makes
    it fall back to `--noTLS`. The bootstrap applies both tables.
  - The vrnetlab launcher resets the guest admin password to containerlab's
    `PASSWORD` env (default `admin`); the guest is reachable over SSH on the
    **launcher's own mgmt IP**, not 127.0.0.1 (loopback→slirp stalls).
  - The image default config gives every node `Loopback0=10.1.0.1/32` and
    bgpd AS 65100/route-id 10.1.0.1 — test topologies must not use 10.1.0.1
    as a peer address (martian-dropped) and must set distinct router-ids.
  - The guest kernel (SONiC Debian 6.1) has **no kernel seg6 lwtunnel**
    support: the kernel-side `encap seg6` dataplane witnesses are
    auto-skipped on this profile; SRv6 control-plane state is still asserted
    over gNMI. Kernel seg6 witnesses run on the `sonic-vs` profile.
  - Persistence on `sonic-vm` is verified with a guest `config reload`
    (re-reads `/etc/sonic/config_db.json`) rather than a container restart.
- **Two pinned images have no local build step** (`grafana/flow-plugin`,
  `ghcr.io/agentic-netops/topology-generator`); `deployment/ui` ends in `ImagePullBackOff`.
- **`docs/INTENT_TIER_OPS_READINESS.md` holds resource figures that were never
  measured.** Re-measure before relying on them.

## Troubleshooting

| Symptom | Cause | Check |
| --- | --- | --- |
| Overlay ping 100% loss, BGP healthy | `vtep1-100` not enslaved to Bridge → bgpd has 0 L2 VNIs | `ip -d link show vtep1-100 \| grep master` |
| `show evpn vni` empty on one leaf | zebra started before the vxlan devices existed | restart `zebra`, then `bgpd` |
| Leaf→leaf IPv6 fails, leaf→spine works | IPv6 forwarding off on the transit node | `sysctl net.ipv6.conf.all.forwarding` |
| gNMI `Unauthenticated` | credentials rotated by a re-provision | re-read the `gnmi-lab-creds` secret |
| `namespaces "kubenet-system" not found` | wrong kubectl context | `kubectl config current-context` |

A provision log ending in a bash syntax error on a valid line usually means the script
was edited *while running* — bash reads scripts by byte offset. Compare the script's
mtime against the failure timestamp before believing the code is wrong.
