// SPDX-License-Identifier: Apache-2.0
package render

import "github.com/mairp/ainetops/pkg/model"

// RenderSRv6 renders SRv6 global and MySID behaviors using SONiC-native paths for the pinned image.
func RenderSRv6(locator model.SRv6Locator, mysid []model.MySID) map[string]any {
	res := map[string]any{}
	res["/sonic-srv6:sonic-srv6/SRV6_GLOBAL"] = map[string]any{"locator-prefix": locator.Prefix}
	// MySID entries simplified; real path would be sonic-srv6 tables
	list := make([]map[string]any, 0, len(mysid))
	for _, m := range mysid {
		entry := map[string]any{"sid": m.SID, "behavior": m.Behavior}
		if m.VRF != "" { entry["vrf"] = m.VRF }
		list = append(list, entry)
	}
	res["/sonic-srv6:sonic-srv6/MYSID"] = list
	return res
}
