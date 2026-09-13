# Contract: SR Linux rendering (pkg/fabricplan)

All paths are SR Linux native (module prefixes omitted, as gnmic/SR Linux accept
them). Values are JSON-IETF objects. `<P>` is the resolved port
(`opts.Ports.Port(att.Attachment)`), `<V>` the vlan, `<L2>` the l2vni,
`<L3>` the l3vni, `<T>` = `L3VLANForVNI(<L3>)`, `<VRF>` = `DeviceVRFName(router.name)`.

## Common: port and subinterface

```
update /interface[name=<P>]            {"admin-state":"enable","vlan-tagging":true,"mtu":9216}
update /interface[name=<P>]/subinterface[index=<idx>]
   bridged: {"type":"bridged","admin-state":"enable","vlan":{"encap":{"single-tagged":{"vlan-id":<idx>}}}}
   routed : {"type":"routed","admin-state":"enable","vlan":{"encap":{"single-tagged":{"vlan-id":<idx>}}},
             "ipv4":{"admin-state":"enable","address":[{"ip-prefix":"<first-host>/<len>"}]}}
```
The bootstrap uses `subinterface[index=0]` untagged on `ethernet-1/3` for the
client domain; services never touch index 0 except the acl-only binding rule.

## vlan (local)

```
update /network-instance[name=vlan-<V>] {"type":"mac-vrf","admin-state":"enable","interface":[{"name":"<P>.<V>"}]}
checks: gnmi-equals /network-instance[name=vlan-<V>]/oper-state == up
        gnmi-equals /interface[name=<P>]/subinterface[index=<V>]/oper-state == up
rollback: delete /network-instance[name=vlan-<V>]; delete /interface[name=<P>]/subinterface[index=<V>]
```

## mac-vrf

```
update /tunnel-interface[name=vxlan1]/vxlan-interface[index=<L2>]
   {"type":"bridged","ingress":{"vni":<L2>},"egress":{"source-ip":"use-system-ipv4-address"}}
update /network-instance[name=<NI>]
   {"type":"mac-vrf","admin-state":"enable",
    "interface":[{"name":"<P>.<V>"}],
    "vxlan-interface":[{"name":"vxlan1.<L2>"}],
    "protocols":{
      "bgp-evpn":{"bgp-instance":[{"id":1,"admin-state":"enable","vxlan-interface":"vxlan1.<L2>","evi":<L2>,"ecmp":2}]},
      "bgp-vpn":{"bgp-instance":[{"id":1,"route-distinguisher":{"rd":"<RD>"},
                 "route-target":{"export-rt":"target:<RT>","import-rt":"target:<RT>"}}]}}}
checks: NI oper-state up; /network-instance[name=<NI>]/protocols/bgp-evpn/bgp-instance[id=1]/oper-state == up
        /tunnel-interface[name=vxlan1]/vxlan-interface[index=<L2>]/oper-state == up (verify live: leaf name)
        gnmi-list-min /tunnel-interface[name=vxlan1]/vxlan-interface[index=<L2>]/bridge-table/multicast-destinations/destination >= 1
rollback: delete NI; delete vxlan-interface[<L2>]; delete subinterface[<V>]
```
`<NI>` = sanitised bridgeDomain name, else `macvrf-<V>`. When RD is empty the
`route-distinguisher` object is omitted (SR Linux auto-derives `<system-ip>:<evi>`).

## ip-vrf

```
update /interface[name=<P>]/subinterface[index=<T>]  (routed, tag <T>, address first host of prefixes[0])
update /tunnel-interface[name=vxlan1]/vxlan-interface[index=<L3>] {"type":"routed","ingress":{"vni":<L3>},"egress":{"source-ip":"use-system-ipv4-address"}}
update /network-instance[name=<VRF>]
   {"type":"ip-vrf","admin-state":"enable","interface":[{"name":"<P>.<T>"}],
    "vxlan-interface":[{"name":"vxlan1.<L3>"}],
    "protocols":{"bgp-evpn":{"bgp-instance":[{"id":1,"admin-state":"enable","vxlan-interface":"vxlan1.<L3>","evi":<L3>,"ecmp":2}]},
                 "bgp-vpn":{"bgp-instance":[{"id":1,"route-distinguisher":{"rd":"<RD>"},"route-target":{"export-rt":"target:<RT>","import-rt":"target:<RT>"}}]}}}
checks: NI up; subinterface up; bgp-evpn instance up; vxlan-interface up
        gnmi-contains /network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-out-post/ip-prefix-routes  expect "<masked prefix>"  (verify live: list path)
rollback: delete NI; delete vxlan-interface[<L3>]; delete subinterface[<T>]
```
IPv6 prefixes add `"ipv6":{"admin-state":"enable","address":[...]}` on the subinterface.

## IRB (bridgeDomain with irb)

mac-vrf as above with `irb0.<V>` added to `interface`, plus:
```
update /interface[name=irb0]/subinterface[index=<V>]
   {"admin-state":"enable","ipv4":{"admin-state":"enable","address":[{"ip-prefix":"<gw4>","anycast-gw":true}]},
    "ipv6":{...optional...},"anycast-gw":{}}
update /network-instance[name=<VRF>]  ip-vrf as above but interface list = [irb0.<V>] (no wan subinterface)
checks: ip-vrf + mac-vrf checks; /interface[name=irb0]/subinterface[index=<V>]/oper-state == up
```

## acl

```
update /acl/acl-filter[name=<F>,type=<ipv4|ipv6>]
   {"entry":[{"sequence-id":<prio>,"match":{"ipv4":{"protocol":"tcp","source-ip":{"prefix":"10.0.0.0/24"}},"transport":{"destination-port":{"value":443}}},"action":{"accept":{}}}, ...,
             {"sequence-id":65535,"action":{"drop":{}}}]}   # default action, when declared
update /interface[name=<P>]/subinterface[index=<idx>]/acl/input  {"acl-filter":[{"name":"<F>","type":"ipv4"}]}   # or output for egress
checks: gnmi-exists /acl/acl-filter[name=<F>,type=ipv4]/entry[sequence-id=<prio>]
        gnmi-exists /interface[name=<P>]/subinterface[index=<idx>]/acl/input/acl-filter[name=<F>,type=ipv4]
        gnmi-exists /acl/acl-filter[name=<F>,type=ipv4]/entry[sequence-id=<prio>]/statistics   (applied side; verify live)
rollback: delete the binding(s); delete /acl/acl-filter[name=<F>,type=ipv4]
```
`<idx>` = every subinterface this Network renders on `<P>`; acl-only Networks
use index 0 and create it as `type routed` in `default` when absent
(documented limitation, mirrors SONiC's port-level binding).
ICMPv6 as protocol stays refused (parity with the original); `l3v6` maps to `type ipv6` with `ipv6` match objects.

## Unit-test obligations (`pkg/fabricplan/plan_test.go`, `tests/unit`)

- Golden plans for vlan, mac-vrf, ip-vrf, IRB, acl on a two-leaf site; byte-stable JSON.
- Every rendered path is present in `pkg/register/oc_vs_srlinux.yaml` (register guard).
- RT normalisation, RD omission, EVI derivation, L3VLAN band refusal, unknown port refusal, no-usable-attachment refusal.
