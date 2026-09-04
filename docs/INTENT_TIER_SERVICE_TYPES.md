# What each service type actually renders on the fabric

**Date:** 2026-09-04
**Touches:** `pkg/fabricplan/plan.go`, `pkg/kubenet/network.go`, `pkg/migration/`,
`cmd/fabric-executor/main.go`, `controllers/sonicprovider/network_controller.go`,
`agents/provisioning/{mapper,allocator}/agent.py`

The tier advertises four service types (VPWS, VPLS, L3VPN, L2L3-IRB). Until
this change **only L3VPN could ever converge**: every VPLS, VPWS and IRB ever
submitted failed at the fabric, after the objects were already on the cluster
and after the deployer had reported a successful submission. This document
records what each type renders now, what was broken, and what is still limited.

## Per-type render contract

| Type | CONFIG_DB / redis | Kernel | FRR | Verified by |
| --- | --- | --- | --- | --- |
| **L3VPN** | `VRF` row (GCU), `VLAN\|Vlan<L3VLAN>`, `VXLAN_TUNNEL_MAP` for the L3VNI | `Vlan<L3VLAN>` SVI in the VRF carrying the service prefix; access port in the Bridge on that vlan; the L3VNI's `vtep1-<L3VLAN>` bridged | `vrf/vni`, `router bgp <asn> vrf`, `redistribute connected`, `advertise <afi>`, RD/RT | VRF row, tunnel map, SVI master + address, vtep master + VNI, `Tenant VRF`, RD-scoped Type-5 |
| **VPLS / VPWS** | `VLAN\|Vlan<vlan>`, `VXLAN_TUNNEL_MAP` for the L2VNI | access port in the Bridge on the service vlan; the L2VNI's `vtep1-<vlan>` bridged | `router bgp <node asn>` → `address-family l2vpn evpn` → `vni <l2vni>` with RD/RT | VXLAN tunnel present, VLAN row, tunnel map, port master + vid, vtep master + vid + VNI, `RD:` under the VNI |
| **L2L3-IRB** | both of the above | both of the above, plus the bridge domain's own SVI in the VRF carrying the tenant gateway | both of the above | both of the above, plus gateway SVI master + every gateway address, plus a Type-5 route per gateway |

VPWS renders as VPLS with an explicit `vpwsLimitedEquivalence` opt-in — the
limited-equivalence mapping the translator has always annotated.

## What was broken

**Every L2 service allocated a VLAN per endpoint.** A bridge domain is one
broadcast domain and the translator renders exactly one `bridgeDomain`, taking
its vlan from the first endpoint. The allocator handed endpoint 2 a different
vlan, so the second attachment referenced a vlan no bridge domain declared and
the fabric rejected the object at render time. VPLS carried a partial guard
against this; VPWS and IRB had none. Fixed in the allocator (one service vlan,
and two *requested* vlans are a rejection rather than a silent pick) and
enforced for all three types in the Go validator.

**The L2 path addressed the VXLAN device by VNI.** SONiC's vxlanmgrd names it
after the VLAN (`vni 1000` lands as `vtep1-2000`). Every `vtep1-<l2vni>`
command was a silent no-op against a device that does not exist, so the bridge
domain would have stayed local-only even once it rendered. The renderer now
waits for `vtep1-<vlan>`, ensures it is a Bridge port in the service vlan, and
**verifies the VNI it actually carries** — a new `link-vxlan-id` check, because
membership checks alone cannot tell a service's own device from one it
inherited from a service that already held that vlan (seen live: leaf01
`vtep1-300` carrying vni 10021 for a service allocated 10022, with every other
check passing).

**`address-family l2vpn evpn` was sent to vtysh at top level.** It is not a
command there — `% Unknown command`. It lives inside the node's own *default*
BGP instance, whose ASN is the leaf's fabric eBGP ASN (65101/65102), not the
65000 the routed path uses for its per-VRF instances; `router bgp` with no ASN
is refused outright. The node is now asked for its own ASN before the vtysh
call is made, and the same block is appended to `bgpd.conf` for durability.

**IRB silently rendered as a VPLS.** `kubenet.BridgeDomain` had no `irb` field,
so the gateway and its VRF were dropped on the floor; and the translator set
`irb.vrf` to a tenant-scoped label that never matched the per-service router it
emitted. Both are fixed, and a bridge domain whose `irb.vrf` names no router in
the same Network is now a rejection rather than a half-rendered service.

**A port's untagged role was stolen by each new service.** The L2 path probed
for an existing PVID through a JSON key iproute2 does not emit (the flags are a
list), so it always concluded "no PVID" and claimed untagged for itself. Both
paths now claim untagged only when no service holds it, and land tagged
otherwise — one physical port carries several services without the newest one
silently breaking the others.

**Nothing checked the intent against the site until after submission.** An
endpoint naming a node or port this fabric does not have was translated,
submitted, and only then rejected by the controller — leaving a stranded
Network, nothing rolled back, and a message that never said what the valid
names were. The Go translator (the last gate before objects exist) now
validates endpoints against the site's own two maps and refuses with the real
names listed; the renderer's own rejection lists them too; and case and
separators are folded, so `Ethernet1` resolves like `ethernet1` at the port
map, the executor's node map, and the site validator alike.

**The L3VNI pool could hand out unrenderable ids.** SONiC needs a VLAN per VNI
and the renderer derives one as `4000 + (vni - 10000)`, so only 10000-14094 has
a VLAN to derive — while the pool's ceiling was 20000. The pool now stops at
14094 and the translator refuses an L3VNI outside the band.

**The renderer raced vlanmgrd for ownership of the Vlan device — and won.**
vlanmgrd builds `Vlan<id>` from the CONFIG_DB `VLAN` row and only then marks
the vlan ready in STATE_DB (`VLAN_TABLE|Vlan<id>`), which is the signal
vxlanmgrd waits on before building the VXLAN device. The renderer created the
device itself, so when it got there first vlanmgrd's own create failed — and
vlanmgrd does **not** retry: the vlan never became ready and the VXLAN device
was never built at all (observed live: `Vlan115` present, no
`VLAN_TABLE|Vlan115`, no `vtep1-115`, service dead). The L3 path had been
losing that race and getting away with it for its whole life. The renderer now
waits for the manager and builds the device itself only if it never appears.

**bgpd could miss an L3VNI that zebra knew about.** A service with a correct
VRF row, SVI, bridged VXLAN device and `vrf X / vni N` in FRR still answered
`VNI not found` to `show bgp l2vpn evpn vni N`, and no reconcile could heal it
because every op was already a no-op. The plan now re-issues the VRF→VNI
binding when — and only when — bgpd has not adopted it, so the reconcile loop
converges instead of failing the same check forever. This healed a live L3VPN
that had been stuck on it.

**A rollback could kill vlanmgrd, and with it every future L2 service.** The
teardown ran `ip link del Vlan<id>` on devices vlanmgrd owns. When vlanmgrd
later ran its own delete for the withdrawn CONFIG_DB row and found the device
already gone, it treated the shell failure as fatal and **exited**
(`Cannot find device "Vlan4031"` … `exited: vlanmgrd (exit status 255)`), and
supervisord did not bring it back. From then on no VLAN on that node got a
device or a `VLAN_TABLE` entry, so no VXLAN device was ever built and every
subsequent L2 service on that leaf failed — a fault whose cause was one
service's *deletion*. Rollback now withdraws the declared rows and lets each
device's own manager remove the device; it only unwinds the port vlan
membership, which is genuinely the renderer's.

**A converged service was never looked at again.** The controller returned no
requeue once a Network was Ready, so device state that drifted afterwards — a
manager daemon that died, a reboot, another service's teardown taking a shared
device with it — left the Network claiming `Ready=True` over a fabric that no
longer matched it (observed live: nine L3VPNs Ready with their SVIs gone).
Every op and check is idempotent, so converged Networks are now re-applied and
re-verified every five minutes: a resync either confirms the service or repairs
it and says so.

**An object naming an unknown node could not be deleted.** The rollback held
the finalizer forever on an executor error, including the executor's permanent
`node "leaf1" not in site map` refusal. A 4xx from the executor is now
distinguished from an outage: nothing was ever applied on a node the site does
not have, so the finalizer is released instead of held.

## Still limited

**IPv6 IRB gateways.** An IRB now carries only the address families the
operator asked for. If IPv6 *is* requested, the address is put on the SVI and
`advertise ipv6 unicast` is configured, but on this sonic-vs FRR build zebra
sometimes registers the global IPv6 address as a **kernel** rather than a
**connected** route (observed on leaf02 while leaf01 was correct for the same
service), and `redistribute connected` then never originates the Type-5. The
service reports `Ready=False` naming the missing route — truthfully — rather
than claiming success. `ip addr replace`, a del/add cycle, and a VRF-membership
bounce were all tried live and none re-registered it.

**One untagged service per port.** Inherent: a port has one PVID. The first
service on a port claims it; later ones are tagged.

**One L2VNI per VLAN per node.** SONiC keys the VXLAN device by VLAN, so two
services cannot share a vlan on one node. The allocator's pool keeps them
distinct; an operator who names the same vlan twice gets the collision, and the
`link-vxlan-id` check is what makes it visible instead of silent.
