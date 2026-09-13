# Construct reference — what each construct renders on the fabric

Target: Nokia SR Linux (`ghcr.io/nokia/srlinux`), EVPN/VXLAN.
Touches: `pkg/fabricplan/plan.go`, `pkg/kubenet/network.go`, `pkg/migration/`,
`cmd/fabric-executor/main.go`, `controllers/srlprovider/network_controller.go`,
`agents/provisioning/{mapper,allocator}/agent.py`

The intent tier expresses four datacenter constructs and nothing else:

- **vlan** — a local broadcast domain: a VLAN and the ports in it
- **mac-vrf** — a VLAN extended over the fabric by an L2VNI with EVPN route targets
- **ip-vrf** — a routed instance: a VRF with an L3VNI and route targets
- **acl** — a filter bound to the ports a service attaches on

The vocabulary is unchanged by the SR Linux migration; only the device objects
underneath it changed. Legacy service-provider names are migration aliases only;
see "Migration aliases" below.

## Required variables and render contract per construct

Ports are logical in the intent (`ethernet1`, `ethernet2`, `ethernet3`, `wan1`)
and resolved through `FABRIC_PORT_MAP` to `ethernet-1/3` (client-facing) and
`ethernet-1/4` (wan). `<V>` is the vlan, `<L2>`/`<L3>` the VNIs,
`<T>` = `L3VLANForVNI(<L3>)` in the reserved 4001-4094 band, `<VRF>` the
`DeviceVRFName` of the router.

| Construct | Required variables | Optional variables | Device objects (gNMI Set, JSON-IETF) | Verified by (gNMI Get) |
|---|---|---|---|---|
| vlan | tenant, 1 endpoint (node+port), vlan id (if operator-supplied) | — | `interface[<P>]/subinterface[<V>]` type bridged, single-tagged `<V>`; `network-instance[vlan-<V>]` type mac-vrf holding `<P>.<V>` | network-instance `oper-state == up`; subinterface `oper-state == up` |
| mac-vrf | tenant, ≥2 endpoints (or 1 with anycast gateway), service vlan | anycast gateway (IPv4/IPv6), `policies.vpwsLimitedEquivalence` | the vlan objects plus `tunnel-interface[vxlan1]/vxlan-interface[<L2>]` type bridged (ingress vni `<L2>`, egress `use-system-ipv4-address`); the network-instance gains `vxlan1.<L2>`, `protocols/bgp-evpn/bgp-instance[1]` (evi `<L2>`, ecmp 2) and `protocols/bgp-vpn/bgp-instance[1]` with RD/RT | network-instance up; bgp-evpn instance up; vxlan-interface up; **remote VTEP**: `vxlan-interface[<L2>]/bridge-table/multicast-destinations/destination` list length ≥ 1 |
| ip-vrf | tenant, ≥1 endpoint (node + wan1/port), address-family prefixes | — | `interface[<P>]/subinterface[<T>]` type routed, single-tagged `<T>`, first host of the prefix; `vxlan-interface[<L3>]` type routed; `network-instance[<VRF>]` type ip-vrf with `<P>.<T>`, `vxlan1.<L3>`, bgp-evpn (evi `<L3>`) and bgp-vpn RD/RT | network-instance up; subinterface up; bgp-evpn instance up; vxlan-interface up; **Type-5 origination**: the masked prefix present in the EVPN RIB out-post with this RD |
| IRB (mac-vrf + gateway) | as mac-vrf, plus the gateway address(es) and the router the bridge domain binds to | IPv6 gateway | mac-vrf objects plus `interface[irb0]/subinterface[<V>]` with `anycast-gw`; `irb0.<V>` added to both the mac-vrf and the ip-vrf network-instances | the mac-vrf and ip-vrf checks, plus `irb0.<V>` `oper-state == up` |
| acl | tenant, ≥1 endpoint (ports), `acl.name`, `acl.stage` (ingress/egress), `acl.type` (l3/l3v6), `acl.rules[]` | `default_action` | `acl/acl-filter[name=<F>,type=ipv4\|ipv6]` with one entry per rule (sequence-id = priority) and the default entry last; binding under `interface[<P>]/subinterface[<idx>]/acl/input\|output` | the filter and each entry exist; the binding exists under every bound subinterface; the entry's `statistics` are readable (the applied side) |

Notes:
- **RT normalisation**: the allocator emits `65000:N`; SR Linux requires the
  `target:` prefix, so the renderer normalises it. The RD stays `ASN:N`, and
  when the RD is empty the object is omitted so SR Linux derives
  `<system-ip>:<evi>` itself.
- **EVI = VNI** for both L2 and L3 instances (both fall inside 1..65535 for the
  pinned pools).
- For a mac-vrf with an anycast gateway, a per-service ip-vrf is composed: the
  bridge domain's `irb0` subinterface is addressed and the ip-vrf binds the
  L3VNI; both halves are verified.
- An acl-only request renders on every node that has an attachment in the same
  `Network`, bound to that node's own attachment ports only. Because SR Linux
  binds filters to subinterfaces rather than ports, an acl-only `Network` binds
  on subinterface index 0, creating it as `type routed` in `default` if absent.
- Rollback deletes the network-instance, the vxlan-interface, the subinterfaces
  and the acl objects **this** `Network` created, in reverse order, and never an
  object it did not create.

## Migration aliases (for provenance only)

Use only the constructs above in operator-facing vocabulary. Legacy names are
accepted as migration aliases and recorded as provenance; they must never be
presented as something an operator can ask for:

- VPLS → mac-vrf (migration alias)
- VPWS / E-Line → mac-vrf with `policies.vpwsLimitedEquivalence=true` (migration alias)
- L3VPN → ip-vrf (migration alias)
- IRB / L2L3-IRB → mac-vrf with anycast-gateway composition (migration alias)

## Unsupported or out-of-scope (refused before any device change)

These are refused explicitly with named causes; there is no hidden partial
behaviour:
- **SRv6 services.** The SR Linux container has no SRv6 data plane, so
  `SRv6Service` objects report `Ready=False` with reason `CapabilityMissing`
  rather than a fabricated success, and the capability gate records SRv6 as
  `not-applicable` with that reason.
- ICMPv6 as an ACL protocol (parity with the previous generation) — declare IPv6
  rules with other protocols instead.
- L2/MAC forwarding tables as a manageable object; packet mirroring; policers
  and complex QoS; control-plane ACLs; NAT.
- VLAN-wide or fabric-wide ACL binding targets: an acl binds to the service's
  subinterfaces only, never to a whole VLAN or to the entire fabric.
- An `l3vni` outside 10000-14094, which has no attachment subinterface tag to
  derive; a port the site does not have; a `Network` with no usable attachment.

## ACL convergence and the applied view

An acl is converged only when the filter exists, the binding exists on every
bound subinterface on every bound node, and the applied side can be read back.
On SR Linux the applied side is the filter entry's own `statistics` container:
an entry that has been programmed reports statistics, one that has not does not.
Where the applied view cannot be read, the operator-facing status names that
property and the node rather than claiming it as verified.

> **Verify live.** The exact list path for the EVPN RIB Type-5 check, the
> vxlan-interface leaf names and the acl `statistics` path are marked *verify
> live* in `specs/001-agentic-netops-srlinux-evpn-fabric/research.md` (D5) and
> have not been read back off a running 26.7.2 node from this tree. Phase 4 of
> the plan confirms or corrects them.

## Design invariants (why the renderer is shaped this way)

These invariants were established on the previous fabric — several of them the
hard way — and are carried forward because they are properties of the intent
model, not of the platform:

- **One VLAN per endpoint.** A bridge domain is one broadcast domain;
  allocation and validation enforce a single service VLAN, and a second named
  VLAN is a refusal.
- **IRB carries its routed half.** The data model carries `irb`, and the
  translator rejects a bridge domain whose `irb.vrf` names no router in the same
  `Network`.
- **Site inventory validation lives in the translator** — the last gate before
  objects exist on the cluster — and names the site's real node and port
  choices in the refusal.
- **The L3VNI pool upper bound matches the renderable band** (10000-14094);
  out-of-band values are refused rather than rendered into nothing.
- **Rollback never deletes what it did not create.**
- **Converged services are re-applied and re-verified every 5 minutes**; drift
  is repaired, or reported truthfully.

Two invariants from that generation are *not* carried forward, because they were
consequences of the SONiC data model:

- "PVID stealing" on access ports has no equivalent here: every service gets its
  own single-tagged subinterface, and two services on the same interface do not
  interfere.
- The VXLAN device-naming and kernel-bridging dance (`vtep1-<vlan>`,
  `VXLAN_TUNNEL_MAP`) is gone: SR Linux models the tunnel as
  `tunnel-interface vxlan1 / vxlan-interface <vni>` and the renderer names it by
  VNI directly.

The record of what was broken on the previous fabric, and how it was found, is
kept in [docs/legacy/](legacy/README.md).

## Known limitations

- **Nothing here has been observed on an SR Linux fabric yet.** The four
  constructs converging to `Ready=True` is Phase 5 of the plan and runs on the
  operator's host; this document states what the renderer emits and what the
  plan checks, not what has been measured. Task T052 adds the dates and the
  measured Enter-to-Deployed seconds once they exist.
- **IPv6 IRB gateways are unexercised on this target.** The IPv6 Type-5
  origination defect recorded on the previous fabric was specific to that
  platform's routing stack; it is not a known defect here, but neither has the
  path been driven.
- **An acl-only service binds on subinterface index 0** (see above) — the
  documented cost of keeping a construct the tier advertises on a platform that
  binds filters to subinterfaces.
