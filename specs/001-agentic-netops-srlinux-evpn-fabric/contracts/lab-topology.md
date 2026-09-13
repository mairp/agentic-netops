# Contract: lab topology and bootstrap (SR Linux)

`lab/topology.clab.yml` (`name: agentic-netops-fabric`, mgmt `agentic-netops-mgmt` 172.31.0.0/16, mtu 9216):

| Node | Kind | Mgmt IP | ASN (underlay) | system0 v4 / v6 |
|---|---|---|---|---|
| spine01 | nokia_srlinux ixrd2l | 172.31.0.11 | 65000 | 10.0.0.11 / 2001:db8:ff::11 |
| spine02 | nokia_srlinux ixrd2l | 172.31.0.12 | 65000 | 10.0.0.12 / 2001:db8:ff::12 |
| leaf01  | nokia_srlinux ixrd2l | 172.31.0.21 | 65101 | 10.0.0.21 / 2001:db8:ff::21 |
| leaf02  | nokia_srlinux ixrd2l | 172.31.0.22 | 65102 | 10.0.0.22 / 2001:db8:ff::22 |
| client01/02 | linux (linux-net) | .101/.102 | — | eth1 192.0.2.11/24, .21/24; 2001:db8:9::11/64, ::21/64 |
| srv6-client01/02 (wan clients) | linux (linux-srv6 image kept) | .111/.112 | — | eth1 192.0.2.31/31, .41/31 |

Links (all mtu 9216): spine01:e1-1↔leaf01:e1-1 (10.1.0.0/31 ↔ .1; 2001:db8:1::3 ↔ ::2),
spine01:e1-2↔leaf02:e1-1 (10.1.0.2 ↔ .3; 2001:db8:1::5 ↔ ::4),
spine02:e1-1↔leaf01:e1-2 (10.1.0.4 ↔ .5; 2001:db8:2::3 ↔ ::2),
spine02:e1-2↔leaf02:e1-2 (10.1.0.6 ↔ .7; 2001:db8:2::5 ↔ ::4),
leaf01:e1-3↔client01:eth1, leaf02:e1-3↔client02:eth1, leaf01:e1-4↔srv6-client01:eth1, leaf02:e1-4↔srv6-client02:eth1.

Startup configs `lab/profiles/srlinux/config/{spine01,spine02,leaf01,leaf02}.cfg`
(SR Linux CLI `set` lines) carry: interfaces + subinterfaces with addresses,
system0, `network-instance default` with the interfaces and BGP
(`autonomous-system`, `router-id`, group `ebgp-underlay` ipv4/ipv6 unicast with
export policy `export-loopbacks`, group `evpn-overlay` `local-as 65535`
`peer-as 65535` afi evpn, multihop, `transport local-address system0`; spines
`route-reflector client true cluster-id <system-ip>`), gNMI server on `mgmt`
port 57400 with `tls-profile clab-profile` (containerlab injects it), leaves
additionally the bootstrap mac-vrf `vlan100` and ip-vrf `VrfBlue` (see research D4).

Profile `lab/profiles/srlinux/profile.yaml` replaces `sonic-vs`; `sonic-vm` is
removed. `scripts/lib/containerlab.sh bootstrap` only: waits for gNMI
Capabilities on each node, creates the generated user, publishes the CA into
`gnmi-lab-tls`. Persistence is the container filesystem + startup-config on
`deploy --reconfigure`.
