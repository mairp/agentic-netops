// SPDX-License-Identifier: Apache-2.0
package render

import (
	"sort"

	"github.com/mairp/agentic-netops/pkg/model"
)

// RenderNetworkInstances renders VRFs and route distinguishers/targets.
func RenderNetworkInstances(instances []model.NetworkInstance) map[string]any {
	res := map[string]any{}
	base := "/network-instances/network-instance"
	// stable order
	names := make([]string, 0, len(instances))
	byName := map[string]model.NetworkInstance{}
	for _, ni := range instances {
		names = append(names, ni.Name)
		byName[ni.Name] = ni
	}
	sort.Strings(names)
	entries := []map[string]any{}
	for _, n := range names {
		ni := byName[n]
		entry := map[string]any{"name": ni.Name, "type": ni.Type}
		if ni.RD != "" {
			entry["rd"] = ni.RD
		}
		if len(ni.ImportRT) > 0 {
			entry["import-rt"] = append([]string{}, ni.ImportRT...)
		}
		if len(ni.ExportRT) > 0 {
			entry["export-rt"] = append([]string{}, ni.ExportRT...)
		}
		entries = append(entries, entry)
	}
	res[base] = entries
	return res
}

// RenderVXLAN renders NVO/VTEP and L2VNI/VLAN bridges placeholders to OpenConfig-preferring paths.
func RenderVXLAN(vx model.VXLAN, vlans []model.VLAN) map[string]any {
	res := map[string]any{}
	// For MVP scaffold, record VTEP source-interface and UDP port under a canonical key
	res["/interfaces/interface[vtep]"] = map[string]any{"source-interface": vx.SourceInterface, "udp-port": vx.UDPPort}
	// Bridges/VLANs simplified
	ids := make([]int, 0, len(vlans))
	byID := map[int]model.VLAN{}
	for _, v := range vlans {
		ids = append(ids, v.ID)
		byID[v.ID] = v
	}
	sort.Ints(ids)
	bridges := []map[string]any{}
	for _, id := range ids {
		v := byID[id]
		bd := map[string]any{"vlan": v.ID, "name": v.Name}
		if v.L2VNI != 0 {
			bd["l2vni"] = v.L2VNI
		}
		bridges = append(bridges, bd)
	}
	res["/network-instances/network-instance/bridges"] = bridges
	return res
}
