#!/usr/bin/env python3
"""Generate lab/profiles/srlinux/config/<node>.cfg (SR Linux CLI `set` syntax).

Kept as a generator so the four nodes cannot drift: every address below is the
single source for the addressing table in
specs/001-agentic-netops-srlinux-evpn-fabric/contracts/lab-topology.md.
"""
import os

CFG = os.path.dirname(os.path.abspath(__file__))

OVERLAY_AS = 65535
L2VNI = 100
L3VNI = 2000

NODES = {
    "spine01": dict(
        role="spine", asn=65000, sys4="10.0.0.11", sys6="2001:db8:ff::11",
        links=[("ethernet-1/1", "10.1.0.0/31", "2001:db8:1::3/127", "10.1.0.1", "2001:db8:1::2", 65101),
               ("ethernet-1/2", "10.1.0.2/31", "2001:db8:1::5/127", "10.1.0.3", "2001:db8:1::4", 65102)],
        overlay_peers=["10.0.0.21", "10.0.0.22"],
    ),
    "spine02": dict(
        role="spine", asn=65000, sys4="10.0.0.12", sys6="2001:db8:ff::12",
        links=[("ethernet-1/1", "10.1.0.4/31", "2001:db8:2::3/127", "10.1.0.5", "2001:db8:2::2", 65101),
               ("ethernet-1/2", "10.1.0.6/31", "2001:db8:2::5/127", "10.1.0.7", "2001:db8:2::4", 65102)],
        overlay_peers=["10.0.0.21", "10.0.0.22"],
    ),
    "leaf01": dict(
        role="leaf", asn=65101, sys4="10.0.0.21", sys6="2001:db8:ff::21",
        links=[("ethernet-1/1", "10.1.0.1/31", "2001:db8:1::2/127", "10.1.0.0", "2001:db8:1::3", 65000),
               ("ethernet-1/2", "10.1.0.5/31", "2001:db8:2::2/127", "10.1.0.4", "2001:db8:2::3", 65000)],
        overlay_peers=["10.0.0.11", "10.0.0.12"],
        lo2000="192.168.201.1/32",
    ),
    "leaf02": dict(
        role="leaf", asn=65102, sys4="10.0.0.22", sys6="2001:db8:ff::22",
        links=[("ethernet-1/1", "10.1.0.3/31", "2001:db8:1::4/127", "10.1.0.2", "2001:db8:1::5", 65000),
               ("ethernet-1/2", "10.1.0.7/31", "2001:db8:2::4/127", "10.1.0.6", "2001:db8:2::5", 65000)],
        overlay_peers=["10.0.0.11", "10.0.0.12"],
        lo2000="192.168.202.1/32",
    ),
}


def emit(name, n):
    L = []
    a = L.append

    # --- routing policy -----------------------------------------------------
    a("set / routing-policy prefix-set loopbacks prefix 10.0.0.0/24 mask-length-range 32..32")
    a("set / routing-policy prefix-set loopbacks prefix 2001:db8:ff::/64 mask-length-range 128..128")
    a("set / routing-policy policy export-loopbacks statement 10 match prefix-set loopbacks")
    a("set / routing-policy policy export-loopbacks statement 10 action policy-result accept")
    a("set / routing-policy policy all default-action policy-result accept")

    # --- fabric interfaces --------------------------------------------------
    for port, v4, v6, _p4, _p6, _pas in n["links"]:
        a(f"set / interface {port} admin-state enable")
        a(f"set / interface {port} mtu 9216")
        a(f"set / interface {port} subinterface 0 admin-state enable")
        a(f"set / interface {port} subinterface 0 ipv4 admin-state enable")
        a(f"set / interface {port} subinterface 0 ipv4 address {v4}")
        a(f"set / interface {port} subinterface 0 ipv6 admin-state enable")
        a(f"set / interface {port} subinterface 0 ipv6 address {v6}")

    # --- access / wan interfaces (leaves only) ------------------------------
    if n["role"] == "leaf":
        a("set / interface ethernet-1/3 admin-state enable")
        a("set / interface ethernet-1/3 mtu 9216")
        a("set / interface ethernet-1/3 vlan-tagging true")
        a("set / interface ethernet-1/3 subinterface 0 type bridged")
        a("set / interface ethernet-1/3 subinterface 0 admin-state enable")
        a("set / interface ethernet-1/3 subinterface 0 vlan encap untagged")
        a("set / interface ethernet-1/4 admin-state enable")
        a("set / interface ethernet-1/4 mtu 9216")
        a("set / interface ethernet-1/4 vlan-tagging true")
        a("set / interface lo0 admin-state enable")
        a(f"set / interface lo0 subinterface {L3VNI} admin-state enable")
        a(f"set / interface lo0 subinterface {L3VNI} ipv4 admin-state enable")
        a(f"set / interface lo0 subinterface {L3VNI} ipv4 address {n['lo2000']}")

    # --- system0 ------------------------------------------------------------
    a("set / interface system0 admin-state enable")
    a("set / interface system0 subinterface 0 admin-state enable")
    a("set / interface system0 subinterface 0 ipv4 admin-state enable")
    a(f"set / interface system0 subinterface 0 ipv4 address {n['sys4']}/32")
    a("set / interface system0 subinterface 0 ipv6 admin-state enable")
    a(f"set / interface system0 subinterface 0 ipv6 address {n['sys6']}/128")

    # --- default network-instance ------------------------------------------
    a("set / network-instance default type default")
    a("set / network-instance default admin-state enable")
    for port, *_ in n["links"]:
        a(f"set / network-instance default interface {port}.0")
    a("set / network-instance default interface system0.0")

    # --- BGP: globals -------------------------------------------------------
    a("set / network-instance default protocols bgp admin-state enable")
    a(f"set / network-instance default protocols bgp autonomous-system {n['asn']}")
    a(f"set / network-instance default protocols bgp router-id {n['sys4']}")
    a("set / network-instance default protocols bgp afi-safi ipv4-unicast admin-state enable")
    a("set / network-instance default protocols bgp afi-safi ipv6-unicast admin-state enable")
    a("set / network-instance default protocols bgp afi-safi evpn admin-state enable")

    # --- BGP: eBGP underlay group ------------------------------------------
    g = "set / network-instance default protocols bgp group ebgp-underlay"
    a(f"{g} admin-state enable")
    a(f"{g} afi-safi ipv4-unicast admin-state enable")
    a(f"{g} afi-safi ipv6-unicast admin-state enable")
    a(f"{g} afi-safi evpn admin-state disable")
    a(f"{g} export-policy [ export-loopbacks ]")
    a(f"{g} import-policy [ all ]")
    a(f"{g} timers minimum-advertisement-interval 1")
    for _port, _v4, _v6, p4, p6, pas in n["links"]:
        for peer in (p4, p6):
            a(f"set / network-instance default protocols bgp neighbor {peer} peer-group ebgp-underlay")
            a(f"set / network-instance default protocols bgp neighbor {peer} peer-as {pas}")

    # --- BGP: iBGP EVPN overlay group --------------------------------------
    g = "set / network-instance default protocols bgp group evpn-overlay"
    a(f"{g} admin-state enable")
    a(f"{g} peer-as {OVERLAY_AS}")
    a(f"{g} local-as as-number {OVERLAY_AS}")
    a(f"{g} afi-safi evpn admin-state enable")
    a(f"{g} afi-safi ipv4-unicast admin-state disable")
    a(f"{g} afi-safi ipv6-unicast admin-state disable")
    a(f"{g} export-policy [ all ]")
    a(f"{g} import-policy [ all ]")
    a(f"{g} timers minimum-advertisement-interval 1")
    a(f"{g} multihop admin-state enable")
    a(f"{g} multihop maximum-hops 2")
    if n["role"] == "spine":
        a(f"{g} route-reflector client true")
        a(f"{g} route-reflector cluster-id {n['sys4']}")
    for peer in n["overlay_peers"]:
        a(f"set / network-instance default protocols bgp neighbor {peer} peer-group evpn-overlay")
        a(f"set / network-instance default protocols bgp neighbor {peer} peer-as {OVERLAY_AS}")
        a(f"set / network-instance default protocols bgp neighbor {peer} transport local-address {n['sys4']}")

    # --- bootstrap tenants (leaves only) -----------------------------------
    if n["role"] == "leaf":
        rd_base = n["sys4"]
        a(f"set / tunnel-interface vxlan1 vxlan-interface {L2VNI} type bridged")
        a(f"set / tunnel-interface vxlan1 vxlan-interface {L2VNI} ingress vni {L2VNI}")
        a(f"set / tunnel-interface vxlan1 vxlan-interface {L2VNI} egress source-ip use-system-ipv4-address")
        a(f"set / tunnel-interface vxlan1 vxlan-interface {L3VNI} type routed")
        a(f"set / tunnel-interface vxlan1 vxlan-interface {L3VNI} ingress vni {L3VNI}")
        a(f"set / tunnel-interface vxlan1 vxlan-interface {L3VNI} egress source-ip use-system-ipv4-address")

        a("set / network-instance vlan100 type mac-vrf")
        a("set / network-instance vlan100 admin-state enable")
        a("set / network-instance vlan100 interface ethernet-1/3.0")
        a(f"set / network-instance vlan100 vxlan-interface vxlan1.{L2VNI}")
        a("set / network-instance vlan100 protocols bgp-evpn bgp-instance 1 admin-state enable")
        a(f"set / network-instance vlan100 protocols bgp-evpn bgp-instance 1 vxlan-interface vxlan1.{L2VNI}")
        a(f"set / network-instance vlan100 protocols bgp-evpn bgp-instance 1 evi {L2VNI}")
        a("set / network-instance vlan100 protocols bgp-evpn bgp-instance 1 ecmp 2")
        a(f"set / network-instance vlan100 protocols bgp-vpn bgp-instance 1 route-distinguisher rd {rd_base}:{L2VNI}")
        a(f"set / network-instance vlan100 protocols bgp-vpn bgp-instance 1 route-target export-rt target:{OVERLAY_AS}:{L2VNI}")
        a(f"set / network-instance vlan100 protocols bgp-vpn bgp-instance 1 route-target import-rt target:{OVERLAY_AS}:{L2VNI}")

        a("set / network-instance VrfBlue type ip-vrf")
        a("set / network-instance VrfBlue admin-state enable")
        a(f"set / network-instance VrfBlue interface lo0.{L3VNI}")
        a(f"set / network-instance VrfBlue vxlan-interface vxlan1.{L3VNI}")
        a("set / network-instance VrfBlue protocols bgp-evpn bgp-instance 1 admin-state enable")
        a(f"set / network-instance VrfBlue protocols bgp-evpn bgp-instance 1 vxlan-interface vxlan1.{L3VNI}")
        a(f"set / network-instance VrfBlue protocols bgp-evpn bgp-instance 1 evi {L3VNI}")
        a("set / network-instance VrfBlue protocols bgp-evpn bgp-instance 1 ecmp 2")
        a(f"set / network-instance VrfBlue protocols bgp-vpn bgp-instance 1 route-distinguisher rd {rd_base}:{L3VNI}")
        a(f"set / network-instance VrfBlue protocols bgp-vpn bgp-instance 1 route-target export-rt target:{OVERLAY_AS}:{L3VNI}")
        a(f"set / network-instance VrfBlue protocols bgp-vpn bgp-instance 1 route-target import-rt target:{OVERLAY_AS}:{L3VNI}")

    # --- gNMI server --------------------------------------------------------
    a("set / system gnmi-server admin-state enable")
    a("set / system gnmi-server network-instance mgmt admin-state enable")
    a("set / system gnmi-server network-instance mgmt port 57400")
    a("set / system gnmi-server network-instance mgmt tls-profile clab-profile")

    return "\n".join(L) + "\n"


os.makedirs(CFG, exist_ok=True)
for name, n in NODES.items():
    path = os.path.join(CFG, name + ".cfg")
    with open(path, "w") as f:
        f.write(emit(name, n))
    print("wrote", path)
