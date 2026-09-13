# SR Linux startup-config — verify-live notes

The four `.cfg` files in this directory are applied by containerlab as
`startup-config` on `deploy` and on `deploy --reconfigure`. They contain SR Linux
CLI `set /` statements, one per line, and **no comments**: the CLI accepts `#`
only in interactive script mode, so every remark that would have been a comment
lives here instead.

The files are generated from a single addressing table (see the addressing
contract in `specs/001-agentic-netops-srlinux-evpn-fabric/contracts/lab-topology.md`);
edit the addressing in one place and re-derive all four rather than hand-patching
one node, or the /31 and /127 pairings silently diverge.

Everything below was written from the documented SR Linux idiom and could not be
executed against a live node offline. Phase 4 (`T040`) runs the lab on the host;
each line here is either confirmed and deleted, or corrected **in the tree file**
— never by a manual change on a node (constitution III).

## Confirmed by the coordinator before writing (no longer open)

- RFC 8212: an eBGP group announces and accepts nothing unless **both**
  `export-policy` and `import-policy` are set. Hence `policy all
  default-action policy-result accept` plus `export-policy [ export-loopbacks ]` /
  `import-policy [ all ]` on `ebgp-underlay`, and `[ all ]` on both sides of
  `evpn-overlay`.
- Group/neighbor syntax: `group <name> peer-as`, `... afi-safi <af> admin-state
  enable`, `neighbor <ip> peer-group <name>`, per-neighbor `peer-as`, per-neighbor
  `transport local-address <system0 ip>`, spine `route-reflector client true` +
  `route-reflector cluster-id <system ip>`.
- mac-vrf / vxlan objects and the untagged access subinterface
  (`vlan-tagging true`, `subinterface 0 type bridged`, `subinterface 0 vlan encap
  untagged`).
- An ip-vrf with a routed subinterface or loopback originates the connected
  prefix as an EVPN Type-5 route with no redistribution statement.

## Still to verify live

1. **`mtu 9216` on a fabric port.** Written as `set / interface ethernet-1/1 mtu
   9216`. The ixrd2l default port MTU is larger than 9216, so this is a
   narrowing, not a widening; confirm the leaf name is `mtu` (and not
   `l2-mtu`/`ip-mtu` at this level) and that the subinterface inherits it.
   Proof: `sr_cli "show interface ethernet-1/1 detail"`.
2. **`system0` subinterface 0 carrying both a /32 and a /128.** Confirm SR Linux
   accepts a dual-stack system interface and that `transport local-address`
   resolves to the IPv4 one. Proof: `sr_cli "show interface system0"`.
3. **`ipv6 address 2001:db8:1::2/127` on a fabric subinterface with an eBGP
   session over it.** Confirm the link-local vs global source selection — if the
   session comes up on the link-local address instead, the neighbor statements
   must name the link-local (or `dynamic-neighbors` must be used).
   Proof: `sr_cli "show network-instance default protocols bgp neighbor"`.
4. **`export-policy [ export-loopbacks ]` list syntax.** Some releases accept the
   bare `export-policy export-loopbacks` form for a single entry; the bracketed
   leaf-list form is the documented one. If the commit is rejected, drop the
   brackets in the generator, not on the node.
5. **`prefix-set loopbacks` covering both families in one set.** The set carries
   `10.0.0.0/24 mask-length-range 32..32` and `2001:db8:ff::/64
   mask-length-range 128..128`. Confirm a single prefix-set may mix address
   families in 26.7; if not, split into `loopbacks-v4` / `loopbacks-v6` and give
   `export-loopbacks` a statement per family.
6. **`timers minimum-advertisement-interval 1` at group level.** Confirm the leaf
   exists under `group ... timers` (rather than only under `neighbor ... timers`).
7. **`multihop admin-state enable` / `maximum-hops 2` on `evpn-overlay`.** The
   overlay peers system0-to-system0 across one spine hop; 2 is the documented
   value. Confirm the container names the container `multihop` (not
   `ebgp-multihop`, which is the eBGP-specific spelling).
8. **`local-as as-number 65535` making the session iBGP.** The overlay is iBGP
   between AS 65535 speakers realised with `local-as` over an eBGP underlay.
   Confirm the session shows as internal and that route-reflection works on the
   spines with that `local-as` in effect.
9. **`route-distinguisher rd <system-ip>:<vni>`.** Confirm the leaf is spelled
   `route-distinguisher rd` (a container with an `rd` leaf) and not a bare
   `route-distinguisher`.
10. **`ecmp 2` under `protocols bgp-evpn bgp-instance 1`.** Confirm the leaf name
    and that 2 is accepted for a two-spine fabric.
11. **`egress source-ip use-system-ipv4-address`.** Confirm the enum spelling on
    26.7 (`use-system-ipv4-address` vs an explicit address).
12. **gNMI server statements.** containerlab's own base config already enables the
    gNMI server on `mgmt` with `tls-profile clab-profile`; ours restate it so the
    contract is explicit in the tree. Confirm restating it is a no-op commit and
    that no `services`/`use-authentication` leaf must additionally be set for
    username/password auth to work. Proof: `gnmic ... capabilities` from the host.
13. **Management is deliberately absent from these files.** `mgmt0`, the `mgmt`
    network-instance, the default `admin` user and the TLS profile all come from
    containerlab's generated base config. Getting any of them wrong in a partial
    config would cost management reachability to the node, so they are left
    alone. **Confirmed offline (2026-09-13, containerlab docs/manual/kinds/srl.md
    and nodes/srl/srl.go):** a startup-config whose first byte is not `{` is
    treated as CLI and applied in the post-deploy stage on top of the default
    config, so these partials merge onto the generated base. The `.cfg`
    extension is irrelevant to that detection.
14. **`vlan-tagging true` on `ethernet-1/3` with an untagged subinterface 0.**
    The renderer (Phase 2) adds single-tagged subinterfaces on the same port for
    `vlan` and `mac-vrf` constructs, which requires `vlan-tagging true`; the
    bootstrap client stays untagged on subinterface 0. Confirm both can coexist.
15. **Creating the generated gNMI user over gNMI.** `scripts/lib/containerlab.sh
    bootstrap` writes `/system/aaa/authentication/user[username=agentic]` with
    `{"password": ..., "role": ["admin"]}` using the image default admin
    credentials. Confirm the leaf names (`password` vs `hashed-password`, `role`
    as a leaf-list) and that the user can immediately authenticate over gNMI.
16. **`/tools/system/configuration/save`** — the executor's post-apply persist
    (Phase 2, `contracts/fabric-executor-api.md`). Confirm the path and that an
    empty JSON value is accepted.
17. **Type-5 origination for `192.168.201.1/32` / `192.168.202.1/32`** from
    `lo0.2000` in `VrfBlue`, visible on the peer leaf. Proof:
    `sr_cli "show network-instance default protocols bgp routes evpn route-type 5 summary"`.
18. **`system network-instance protocols bgp-vpn bgp-instance 1`** is deliberately
    not configured: every RD and RT here is explicit, so the system-level
    bgp-vpn instance (needed for auto-derived RD/RT and ethernet segments) should
    not be required. Confirm the bgp-evpn instances come up without it.

## Verify live — state paths the qualification and verification suites read

These are not startup-config statements, but they are the other half of the same
contract: a gate that reads a misspelled path proves nothing. Confirm each
against the live image in Phase 4 and correct the suite file, never the node.

19. **EVPN RIB, received side** —
    `/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post/{mac-ip-routes,imet-routes,ip-prefix-routes}`
    (`tests/integration/evpn_suite.sh`, `tests/integration/fabric_verify.sh`).
    Both suites count entries by counting `"route-distinguisher"` occurrences —
    confirm every route-type list entry carries exactly one, or switch the
    counter to the list's own key leaf.
20. **Remote VTEP list** —
    `/tunnel-interface[name=vxlan1]/vxlan-interface[index=100]/bridge-table/multicast-destinations/destination`
    (confirmed by the coordinator; the entry key leaf is counted as
    `"destination-index"` or `"vtep-address"` — confirm which one 26.7 emits).
    Show equivalent: `show tunnel-interface vxlan1 vxlan-interface 100 bridge-table multicast-destinations destination *`.
21. **BGP session state** —
    `/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state`
    and the negotiated address family at
    `.../neighbor[peer-address=*]/afi-safi[afi-safi-name=evpn]/active`.
    `fabric_verify.sh` requires every session to read `established` and at least
    one neighbor to have the EVPN family active. Confirm the `active` leaf name
    (it may be `oper-state` or `admin-state` on some releases).
22. **`sr_cli` ping from a node** — `ping6 <addr> network-instance default -c 3`,
    with a fallback to `ping <addr> network-instance default -c 3`
    (`fabric_verify.sh` loopback reachability). Confirm the spelling and that the
    output carries a `... 0% packet loss` line.
23. **`gnmic set --update-file`** — used by `scripts/lib/containerlab.sh` so the
    generated password never reaches argv. Confirm gnmic 0.47.0 accepts
    `--update-path` together with `--update-file` for a JSON object value.
24. **`gnmic sub --mode once`** on `/interface[name=ethernet-1/1]/statistics`
    must terminate and deliver `in-octets`/`out-octets`
    (`tests/integration/srlinux_gnmi_suite.sh`).
25. **`/system/information/contact` is unset in these startup configs**, which is
    what makes it a safe Set witness: the suites write it, read it back and
    delete it, restoring the node exactly. Confirm nothing else sets it (in
    particular, that containerlab's base config does not).
