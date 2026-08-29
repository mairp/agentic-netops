// SPDX-License-Identifier: Apache-2.0
// Package model exposes canonical internal structs independent of specific SONiC release.
package model

// Interface represents a physical or logical interface with optional L3 addresses.
type Interface struct {
	Name      string
	MTU       int
	IPv4CIDR  string // allow /31 for point-to-point
	IPv6CIDR  string // required for SRv6 underlay
	Loopback  bool
}

// Loopback represents a loopback interface by name.
type Loopback struct {
	Name string
	IPv4CIDR string
	IPv6CIDR string
}

// BGPGlobal represents global BGP settings.
type BGPGlobal struct {
	ASN          uint32
	RouterID     string
	ListenRanges []string
}

// BGPNeighbor represents a BGP neighbor with AFI/SAFI configuration.
type BGPNeighbor struct {
	NeighborAddress string
	PeerASN         uint32
	IPv4AFI         bool
	IPv6AFI         bool
	EVPN            bool
}

// NetworkInstance models a VRF or default instance.
type NetworkInstance struct {
	Name     string
	Type     string // "DEFAULT" or "L3VRF"
	RD       string
	ImportRT []string
	ExportRT []string
}

// VLAN represents a VLAN and optional L2VNI.
type VLAN struct {
	ID    int
	Name  string
	L2VNI int
}

// VNI represents a VXLAN Network Identifier.
type VNI struct {
	ID int
}

// VXLAN models VTEP and NVO state.
type VXLAN struct {
	SourceInterface string // loopback used as VTEP src
	UDPPort         int
}

// IRB represents symmetric IRB parameters.
type IRB struct {
	GatewayIPv4 string
	GatewayIPv6 string
}

// SRv6Locator represents a locator prefix and length.
type SRv6Locator struct {
	Name   string
	Prefix string // IPv6
}

// MySID represents a MySID behavior at a node.
type MySID struct {
	SID       string // IPv6 SID
	Behavior  string // e.g., End, End.DT46, End.DT6, End.DT4
	VRF       string // for End.DT46/VRF
}

// SIDList represents an ordered list of SIDs for steering.
type SIDList struct {
	Name string
	SIDs []string
}

// SRPolicy represents a steering policy.
type SRPolicy struct {
	Name       string
	Selector   string // match expression or interface
	SIDListRef string
}
