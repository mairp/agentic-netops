# Construct reference — what each construct renders on the fabric

Date: 2026-09-06
Touches: `pkg/fabricplan/plan.go`, `pkg/kubenet/network.go`, `pkg/migration/`,
`cmd/fabric-executor/main.go`, `controllers/sonicprovider/network_controller.go`,
`agents/provisioning/{mapper,allocator}/agent.py`

The intent tier expresses four datacenter constructs and nothing else:

- vlan — a local broadcast domain: a VLAN and the ports in it
- mac-vrf — a VLAN extended over the fabric by an L2VNI with EVPN route targets
- ip-vrf — a routed instance: a VRF with an L3VNI and route targets
- acl — a filter bound to the ports a service attaches on

Legacy service-provider names are migration aliases only; see “Migration aliases” below.

## Required variables and render contract per construct

| Construct | Required variables | Optional variables | CONFIG_DB / redis | Kernel | FRR | Verified by |
|---|---|---|---|---|---|---|
| vlan | tenant, 1 endpoint (node+port), vlan id (if operator-supplied) | — | `VLAN|Vlan<vlan>` (raw redis) | access port enslaved into Bridge with PVID `<vlan>` | — | `redis-hget` on `VLAN`, bridge membership + `bridge-vid` |
| mac-vrf | tenant, ≥2 endpoints (or 1 with anycast gateway), service vlan | anycast gateway (IPv4/IPv6), policies.vpwsLimitedEquivalence | `VLAN|Vlan<vlan>`, `VXLAN_TUNNEL_MAP|vtep1|map_<l2vni>_Vlan<vlan>` (raw redis) | access ports enslaved to Bridge on `<vlan>`; `vtep1-<vlan>` bridged | `router bgp <leaf-asn>` → `address-family l2vpn evpn` → `vni <l2vni>` with RD/RT | VLAN row, tunnel map, port master+vid, vtep master+vid+VNI, EVPN VNI present |
| ip-vrf | tenant, ≥1 endpoint (node+wan1/port), address family prefixes | — | `VRF` row (GCU); `VLAN|Vlan<l3vlan>` + `VXLAN_TUNNEL_MAP` for L3VNI (raw redis) | `Vlan<l3vlan>` SVI enslaved to the VRF; access port bridged on service vlan | `vrf/vni`, `router bgp <asn> vrf`, `redistribute connected`, advertise AFI, RD/RT | VRF row, SVI up+addressed+master, VNI in bgpd, RD‑scoped Type‑5 |
| acl | tenant, ≥1 endpoint (ports), acl.name, acl.stage (ingress/egress), acl.type (l3/l3v6), acl.rules[] | default_action | `ACL_TABLE|<table>` and `ACL_RULE|<rule>` (raw redis only) | bound to each node’s own ports only | — | config side: table+rule rows with exact fields; applied side: table/entry objects in ASIC_DB |

Notes:
- For mac-vrf with anycast gateway, a per-service ip-vrf is composed: the bridge domain’s SVI is addressed and the VRF binds the L3VNI; both are verified.
- An acl-only request renders on every node that has an attachment in the same `Network`, bound to that node’s own attachment ports only.

## Migration aliases (for provenance only)

Use only the constructs above in operator-facing vocabulary. Legacy names are accepted as migration aliases and recorded as provenance; they must never be presented as something an operator can ask for:

- VPLS → mac-vrf (migration alias)
- VPWS / E‑Line → mac-vrf with `policies.vpwsLimitedEquivalence=true` (migration alias)
- L3VPN → ip-vrf (migration alias)
- IRB / L2L3‑IRB → mac-vrf with anycast-gateway composition (migration alias)

## Unsupported or out-of-scope (refused before any device change)

These are refused explicitly with named causes; there is no hidden partial behavior:
- ICMPv6 as an ACL protocol (the pinned image cannot express it in `ACL_RULE`) — declare IPv6 rules with other protocols instead.
- L2/MAC forwarding tables as a manageable object; packet mirroring; policers and complex QoS; control‑plane ACLs; NAT.
- VLAN‑wide or fabric‑wide ACL binding targets: an acl binds to service ports only, never to a whole VLAN or to the entire fabric.

## ACL convergence and the applied view

An acl is converged only when the filter is both present in CONFIG_DB and applied on the device ports it is bound to on every bound node. On SONiC VS the applied view is read from ASIC_DB — the supervisor verifies the ACL table object has a `SAI_ACL_BIND_POINT_TYPE_PORT` bind point for the declared stage and counts at least one `SAI_OBJECT_TYPE_ACL_ENTRY` object per rendered rule. Where the applied view cannot be read, the operator‑facing status names that property and the node rather than claiming it as verified.

## What was broken (now corrected)

The earlier service‑type vocabulary hid several defects that prevented L2 services from converging. All are corrected in this tree:

- One VLAN per endpoint: a bridge domain is one broadcast domain; allocation and validation enforce one service VLAN (second named VLAN is a refusal).
- VXLAN device addressing used the VNI; SONiC names it after the VLAN. The renderer now waits for `vtep1-<vlan>`, bridges it, and verifies the VNI the kernel device actually carries.
- EVPN AF configuration went to the wrong FRR context; it is now placed under the node’s default BGP instance using the leaf’s own ASN and persisted to `bgpd.conf`.
- IRB lost the routed half; the data model carries `irb` and the translator rejects a bridge domain whose `irb.vrf` names no router in the same Network.
- PVID stealing on access ports; ports now keep an existing PVID and later services land tagged.
- Site inventory validation moved to the translator (last gate before objects exist) and names the site’s real node/port choices.
- L3VNI pool upper bound matched the image’s renderable band (10000–14094); out‑of‑band values are refused.
- Rollback never deletes devices the managers own; it withdraws rows and unwinds only the bridge memberships it set.
- Converged services are re‑applied and re‑verified every 5 minutes; drift is repaired or reported truthfully.

## Known limitations

- IPv6 anycast gateways: on this sonic‑vs build zebra may register a global IPv6 address as a kernel route rather than connected; `redistribute connected` then originates no Type‑5. The condition is reported truthfully as not Ready.
- One untagged service per port (inherent; a port has one PVID). Later services land tagged.
- One L2VNI per VLAN per node (inherent to SONiC’s VTEP device keying).
