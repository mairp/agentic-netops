// SPDX-License-Identifier: Apache-2.0
package render

import (
	"sort"

	"github.com/mairp/agentic-netops/pkg/model"
)

// RenderBGP renders BGP global and neighbor config preferring OpenConfig paths.
func RenderBGP(global model.BGPGlobal, neighbors []model.BGPNeighbor) map[string]any {
	res := map[string]any{}
	base := "/network-instances/network-instance"
	// We model default NI for BGP global in OpenConfig; fall back to SONiC-native for gaps
	res[base] = map[string]any{"name": "DEFAULT", "protocols": map[string]any{"bgp": map[string]any{
		"asn":       global.ASN,
		"router-id": global.RouterID,
	}}}
	// Neighbors under OpenConfig
	names := make([]string, 0, len(neighbors))
	for _, n := range neighbors {
		names = append(names, n.NeighborAddress)
	}
	sort.Strings(names)
	neis := make([]map[string]any, 0, len(names))
	byKey := map[string]model.BGPNeighbor{}
	for _, n := range neighbors {
		byKey[n.NeighborAddress] = n
	}
	for _, k := range names {
		n := byKey[k]
		nei := map[string]any{
			"neighbor-address": n.NeighborAddress,
			"peer-as":          n.PeerASN,
		}
		if n.EVPN {
			nei["afi-safi"] = []string{"l2vpn-evpn"}
		}
		neis = append(neis, nei)
	}
	res[base+"/protocols/bgp/neighbors"] = neis
	return res
}
