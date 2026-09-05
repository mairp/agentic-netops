// SPDX-License-Identifier: Apache-2.0
package render

import (
	"sort"

	"github.com/mairp/agentic-netops/pkg/model"
)

// RenderLocalVLANs emits SONiC-native VLAN and VLAN_MEMBER tables for local VLAN constructs.
// The register guard exercises these paths explicitly to prevent silent drift.
//
// Paths:
//   - /sonic-vlan:sonic-vlan/VLAN
//   - /sonic-vlan:sonic-vlan/VLAN_MEMBER
func RenderLocalVLANs(vlans []model.VLAN, members map[int][]string) map[string]any {
	res := map[string]any{}
	// VLAN table entries
	ids := make([]int, 0, len(vlans))
	byID := map[int]model.VLAN{}
	for _, v := range vlans {
		ids = append(ids, v.ID)
		byID[v.ID] = v
	}
	sort.Ints(ids)
	vlanEntries := []map[string]any{}
	for _, id := range ids {
		v := byID[id]
		vlanEntries = append(vlanEntries, map[string]any{"name": v.Name, "vlanid": v.ID})
	}
	res["/sonic-vlan:sonic-vlan/VLAN"] = vlanEntries

	// VLAN_MEMBER table entries: for each vlan, list member ports (untagged for simplicity)
	memberEntries := []map[string]any{}
	for _, id := range ids {
		ports := members[id]
		sort.Strings(ports)
		for _, p := range ports {
			memberEntries = append(memberEntries, map[string]any{"vlan": id, "ifname": p, "tagging_mode": "untagged"})
		}
	}
	res["/sonic-vlan:sonic-vlan/VLAN_MEMBER"] = memberEntries
	return res
}
