// SPDX-License-Identifier: Apache-2.0
package render

import (
	"sort"

	"github.com/mairp/agentic-netops/pkg/model"
)

// RenderInterfaces produces OpenConfig interface entries including loopbacks and MTU.
// Qualifies IPv4 /31 and IPv6 underlay addressing on point-to-point links.
func RenderInterfaces(ifs []model.Interface, lbs []model.Loopback) map[string]any {
	// We render to the OpenConfig /interfaces/interface path.
	res := map[string]any{}
	// Use stable ordering by interface name
	names := make([]string, 0, len(ifs))
	for _, ii := range ifs {
		names = append(names, ii.Name)
	}
	sort.Strings(names)
	entries := make([]map[string]any, 0, len(names))
	byName := map[string]model.Interface{}
	for _, ii := range ifs {
		byName[ii.Name] = ii
	}
	for _, n := range names {
		in := byName[n]
		entry := map[string]any{
			"name": n,
		}
		if in.MTU > 0 {
			entry["mtu"] = in.MTU
		}
		if in.IPv4CIDR != "" {
			entry["ipv4"] = map[string]any{"address": in.IPv4CIDR}
		}
		if in.IPv6CIDR != "" {
			entry["ipv6"] = map[string]any{"address": in.IPv6CIDR}
		}
		entries = append(entries, entry)
	}
	// Add loopbacks as interfaces when provided
	lbNames := make([]string, 0, len(lbs))
	for _, lb := range lbs {
		lbNames = append(lbNames, lb.Name)
	}
	sort.Strings(lbNames)
	lbByName := map[string]model.Loopback{}
	for _, lb := range lbs {
		lbByName[lb.Name] = lb
	}
	for _, n := range lbNames {
		lb := lbByName[n]
		entry := map[string]any{
			"name":     n,
			"loopback": true,
		}
		if lb.IPv4CIDR != "" {
			entry["ipv4"] = map[string]any{"address": lb.IPv4CIDR}
		}
		if lb.IPv6CIDR != "" {
			entry["ipv6"] = map[string]any{"address": lb.IPv6CIDR}
		}
		entries = append(entries, entry)
	}
	res["/interfaces/interface"] = entries
	return res
}
