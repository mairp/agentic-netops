# Research: SR Linux target decisions

Every decision below replaces a SONiC-specific mechanism with its SR Linux
equivalent. "Verify live" marks facts the host run (Phases 5–8) must confirm
against the running image before the phase gate accepts them; the offline
phases render exactly what is written here so a live correction is a one-line
change, not a redesign.

## D1. Image and platform

- **Decision**: `ghcr.io/nokia/srlinux:26.7.2` (manifest-list digest
  `sha256:0096fe3ebcafabb7253492e2060425fe027a168e0e066766d1e85efbb0b48be8`,
  resolved 2026-09-13 from ghcr.io), containerlab kind `nokia_srlinux`, type `ixrd2l`.
- **Rationale**: latest GA release on ghcr at spec time; ixrd2l is the default
  containerlab type, supports EVPN/VXLAN (mac-vrf, ip-vrf, symmetric IRB, ACLs).
  No KVM; ~1.5–2 GB RAM per node, so the 4-node fabric plus kind fits the
  original 8 GB minimum with the documented intent-tier headroom.
- **Alternatives**: `25.10.x` (previous LTS train) — kept as a documented
  fallback pin if a 26.7 regression surfaces live.
- **Verify live**: the amd64 digest under the manifest list, `sr_cli` version banner.

## D2. Southbound write path

- **Decision**: native gNMI Set (JSON_IETF) from the fabric-executor to each
  node's `172.31.0.x:57400`, TLS with the containerlab CA, username/password
  auth with the lab-generated user. The executor keeps its HTTP API and stays
  a host service started by `provision.sh` (unchanged placement; no docker
  socket is mounted anymore).
- **Rationale**: SR Linux gNMI Set is transactional (candidate + commit per
  request); the SONiC executor's GCU/redis/kernel/FRR primitives collapse into
  one primitive. Keeping the executor's HTTP contract means the controller
  changes are limited to op/check types.
- **Alternatives**: JSON-RPC (`/jsonrpc`, CLI method) — rejected as primary
  (CLI strings, no schema); SDC config-server — still placeholder images.
- **Go dependencies**: `github.com/openconfig/gnmi` (proto + client) and
  `google.golang.org/grpc`, vendored. Fallback if vendoring fails offline:
  shell out to the pinned `gnmic` host binary (already in `host_tools`).
- **Persistence**: after a successful apply sequence the executor issues
  `Set update /tools/system/configuration/save` (empty value). **Verify live**;
  fallback is JSON-RPC `cli` `save file`. Persistence is belt-and-braces: the
  controller's 5-minute resync re-applies any drifted service anyway.

## D3. Credentials and TLS

- **Decision**: containerlab generates a per-lab CA and per-node server certs
  (`lab/clab-agentic-netops-fabric/.tls/ca/ca.pem`). Provision copies the CA
  into Secret `gnmi-lab-tls` (`ca.crt`; `tls.crt`/`tls.key` keep the
  generator's client material for API compatibility) and creates user
  `agentic` with the generated password from `gnmi-lab-creds` on every node
  through one gNMI Set using the image default admin credentials, which are
  never stored. gnmic, the executor and the suites use `ca.crt` + user/pass;
  no client cert is required by the SR Linux gNMI server.
- **Verify live**: path `/system/aaa/authentication/user[username=agentic]`
  with `password` and `role [admin]`.

## D4. Underlay and overlay bootstrap

- **Decision**: startup configuration files per node
  (`lab/profiles/srlinux/config/<node>.cfg`, SR Linux CLI `set` syntax),
  referenced by `startup-config` in the topology. No post-boot shell hooks.
  - Underlay: eBGP, spines AS 65000, leaf01 65101, leaf02 65102, dual-stack on
    the original /31 and /127 addressing; system0 loopbacks 10.0.0.11/12 (spines),
    10.0.0.21/22 (leaves) and 2001:db8:ff::11/12/21/22 exported.
  - Overlay: iBGP EVPN, AS 65535 via `local-as`, peer group `evpn-overlay`,
    transport `local-address system0`, multihop 2, spines `route-reflector
    client` with cluster-id = spine system IP.
  - Bootstrap tenants: mac-vrf `vlan100` (evi 100, L2VNI 100, `vxlan1.100`,
    `ethernet-1/3.0` untagged on both leaves) so client01↔client02 exercise the
    overlay; ip-vrf `VrfBlue` (evi 2000, L3VNI 2000, `vxlan1.2000`) with
    `lo0.2000` carrying 192.168.201.1/32 (leaf01) / 192.168.202.1/32 (leaf02),
    originated as Type-5.
- **Rationale**: matches the srl-labs reference fabric designs; iBGP overlay
  with RR spines is the SR Linux idiom and keeps spines free of tenant state
  (FR-004 of the original spec).
- **Verify live**: `show network-instance default protocols bgp neighbor`,
  `show network-instance vlan100 protocols bgp-evpn`, RT5 for 192.168.201.1/32 on leaf02.

## D5. Construct rendering (SR Linux native model)

Attachment port map (`FABRIC_PORT_MAP`): `ethernet1|ethernet2|ethernet3 →
ethernet-1/3`, `wan1 → ethernet-1/4`, plus identity entries `e1-1..e1-4`.

| Construct | Device objects (gNMI Set updates) | Verification (gNMI Get) |
|---|---|---|
| vlan | `interface[ethernet-1/3]/subinterface[<vlan>]` type bridged, `vlan/encap/single-tagged/vlan-id=<vlan>`; `network-instance[vlan-<vlan>]` type mac-vrf with that subinterface | NI `oper-state==up`; subinterface `oper-state==up` |
| mac-vrf | as vlan plus `tunnel-interface[vxlan1]/vxlan-interface[<l2vni>]` type bridged, ingress vni `<l2vni>`, egress source-ip `use-system-ipv4-address`; NI `protocols/bgp-evpn/bgp-instance[1]` (vxlan-interface, `evi=<l2vni>`, ecmp 2); `protocols/bgp-vpn/bgp-instance[1]` RD/RT | NI up; bgp-evpn instance `oper-state==up`; vxlan-interface up; **peer arrival**: `.../vxlan-interface[<l2vni>]/bridge-table/multicast-destinations/destination` list ≥1 (the remote VTEP learned from the peer's IMET — the only signal self-origination cannot fake) |
| ip-vrf | `interface[ethernet-1/4]/subinterface[<l3vlan>]` type routed, single-tagged `<l3vlan>`, ipv4 address first host of the prefix; `tunnel-interface[vxlan1]/vxlan-interface[<l3vni>]` type routed; NI `<vrf>` type ip-vrf with the subinterface and vxlan-interface; bgp-evpn `evi=<l3vni>`; bgp-vpn RD/RT | NI up; subinterface up; bgp-evpn up; **Type-5 origination**: `network-instance[default]/bgp-rib/afi-safi[evpn]/evpn/rib-in-out/rib-out-post/ip-prefix-routes` contains the masked prefix with this RD (verify live: exact list path) |
| IRB (mac-vrf + gateway) | mac-vrf objects + `interface[irb0]/subinterface[<vlan>]` with ipv4/ipv6 address, `anycast-gw true`; mac-vrf NI gets `irb0.<vlan>`; ip-vrf NI gets `irb0.<vlan>`; ip-vrf objects as above without the wan subinterface | mac-vrf and ip-vrf checks; `irb0.<vlan>` up and in the ip-vrf |
| acl | `acl/acl-filter[name=<table>,type=ipv4|ipv6]` entries (sequence-id = rule priority, match protocol/src/dst/ports, action accept/drop, default entry last); bound at `interface[<port>]/subinterface[<idx>]/acl/input|output/acl-filter[name,type]` on every subinterface this Network renders on that port; an acl-only Network binds on subinterface index 0 (created routed in `default` if absent) | filter exists with every entry; binding present under the subinterface; `acl/acl-filter[...]/entry[...]/statistics` readable (applied-side) |

- `<l3vlan>` keeps `L3VLANForVNI` (4001–4094 band) as the ip-vrf attachment
  subinterface tag, so the allocator's L3VNI cap (14094) stays meaningful and
  `DeviceVRFName` stays the on-device name (SR Linux NI names allow up to 255
  chars, so the 14-char cap is now only a stability guarantee).
- RT normalisation: allocator emits `65000:N`; SR Linux requires `target:65000:N`.
  RD stays `65000:N` (SR Linux accepts `ASN:N`).
- EVI: `evi = vni` (both in 1..65535 for the pinned pools).
- Rollback: `delete` of the NI, the vxlan-interface, the subinterface(s) and the
  acl objects this Network created, in reverse order; never objects it did not create.

## D6. Verification semantics in the executor

Check types: `gnmi-equals` (path leaf == expect), `gnmi-contains` (JSON body
contains expect), `gnmi-exists` (path returns a value), `gnmi-list-min` (list
length ≥ minCount), `gnmi-absent`. Gets use `type: ALL`, JSON_IETF, 10 s
timeout; a transport failure is reported as an error, never as absence.

## D7. Telemetry

gnmic subscriptions (sample, 10 s / 30 s):
`/interface[name=ethernet-1/*]/statistics`, `/interface[name=*]/oper-state`,
`/interface[name=*]/subinterface[index=*]/oper-state`,
`/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/session-state`,
`/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/received-routes`,
`/platform/control[slot=*]/cpu[index=all]/total/instant`,
`/platform/control[slot=*]/memory`. Output: gnmic Prometheus on :9273 with
`strings-as-labels: true` and `event-add-tag` for `device`/`interface` labels.
Dashboards are re-pointed at these series (`interface_statistics_in_octets`
etc. as emitted by gnmic's default naming).

## D8. Capability gate and SRv6

`qualify.sh` runs `srlinux_gnmi_suite.sh` (Capabilities/Get/Set/Subscribe with
content assertions and a Set→Get→delete witness on a description leaf),
`persistence.sh` (docker restart of every node, witness re-read), then the
EVPN suite (Type-2/3/5, remote VTEPs, overlay traffic). SRv6 entries are
recorded as `{"status":"not-applicable","reason":"SR Linux 7220 container has no SRv6 data plane"}`.
`fabric-compat-pins` carries `cap-sai-srv6: "false"`; `compat.FullValidate`
only requires SRv6 for `SRv6Service` objects.

## D9. Supply chain policy inversion

`scripts/ci/supply_chain.sh` forbids `\bsonic\b|sonic-vs|sonic-net|sonic_yang`
in `go.mod go.sum cmd config deploy lab`; `make test-static` checks the pinned
SR Linux image is present locally.

## D10. Video proofs

`record.py` router commands become read-only `docker exec <leaf> sr_cli <show …>`:
- vlan: `show network-instance vlan-<v> interfaces`
- ip-vrf: `show network-instance <vrf> summary`, `show network-instance <vrf> route-table ipv4-unicast summary`, `show network-instance default protocols bgp routes evpn route-type 5 summary | grep <prefix>`
- mac-vrf: `show network-instance <ni> summary` on both leaves, `show tunnel-interface vxlan1 vxlan-interface <l2vni> bridge-table multicast-destinations`
- acl: `show acl acl-filter <name> type ipv4`, `show acl summary`
`vlan_lookup()` becomes a `show network-instance summary | grep -i <name>`.
**Verify live**: exact `sr_cli` show syntax on 26.7 before the take (the smoke run asserts every command returns a prompt).
