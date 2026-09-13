# Linux Client Images and Deterministic Addressing

Addressing is declared once, in the per-node `exec:` statements of
`lab/topology.clab.yml`; this file is the reading of it. The leaf side of each
link is named in SR Linux terms (`ethernet-1/3`, `ethernet-1/4`), which is what
`e1-3` / `e1-4` in the topology's `links:` resolve to.

## EVPN clients — bridged, no leaf-side IP

`client01` and `client02` attach to the bootstrap mac-vrf `vlan100` (L2VNI 100)
on `ethernet-1/3.0`, untagged. The leaf holds **no** IP address on that
interface: the subinterface is `type bridged` and the two clients share one
subnet so that cross-leaf Type-2 MAC/IP reachability is exercisable. A /31 per
client would place them in different subnets and there would be nothing for the
overlay to bridge.

- client01 (leaf01 `ethernet-1/3`): `eth1` 192.0.2.11/24, 2001:db8:9::11/64
- client02 (leaf02 `ethernet-1/3`): `eth1` 192.0.2.21/24, 2001:db8:9::21/64

`tests/integration/fabric_verify.sh` and `tests/integration/evpn_suite.sh` ping
client01 → client02 across the overlay; that ping is the end-to-end data-plane
assertion for the bootstrap mac-vrf.

## WAN clients — the `wan1` attachment

`srv6-client01` and `srv6-client02` attach to `ethernet-1/4`, the logical `wan1`
port that the ip-vrf construct renders its routed, single-tagged subinterface
on. The node names are kept for provenance with the previous fabric; SRv6 has no
data plane on this platform and is declared not-applicable by the capability
gate, so these are plain routed endpoints.

- srv6-client01 (leaf01 `ethernet-1/4`): `eth1` 192.0.2.31/31, 2001:db8:3::31/127
- srv6-client02 (leaf02 `ethernet-1/4`): `eth1` 192.0.2.41/31, 2001:db8:4::41/127

The leaf side of these links carries no bootstrap subinterface: `ethernet-1/4` is
brought up with `vlan-tagging true` and stays otherwise empty until a `Network`
renders an ip-vrf attachment onto it.

## Images

Built from `Dockerfile.linux-net` and `Dockerfile.linux-srv6` in this directory
(iproute2, ping, curl, tcpdump; the srv6 variant adds the iproute2 SRv6 tools).
Both are pinned by immutable digest in `versions.lock.yaml`
(`endpoint_images.linux_net`, `endpoint_images.linux_srv6`) and referenced by
that same digest in `lab/topology.clab.yml`.
