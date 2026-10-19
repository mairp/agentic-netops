// SPDX-License-Identifier: Apache-2.0
package render

import (
	"sort"

	"github.com/mairp/agentic-netops/pkg/model"
)

// SRv6 renderer for the pinned SONiC image.
//
// Honest as-built note: these are the only SRv6 tables present in the image's
// YANG schema. The locator rows are bootstrap-owned — a service never writes
// them (FR-006) — and the SRV6_MY_SIDS decap row is measured NOT to program
// the dataplane on the pinned image (proof `spike-sid-write`), so the as-built
// plan uses kernel routes (`ip -6 route ... encap seg6local`) instead. These
// renderers exist so schema-backed CONFIG_DB coverage stays explicit and
// register-guarded, not because a service drives them.
//
// Paths:
//   - /sonic-srv6:sonic-srv6/SRV6_MY_LOCATORS
//   - /sonic-srv6:sonic-srv6/SRV6_MY_SIDS

// RenderSRv6MyLocators emits SRV6_MY_LOCATORS rows, one per node locator.
// Row key format: `loc-<node>` with the /48 locator prefix (data-model §8.2).
func RenderSRv6MyLocators(locators []model.SRv6MyLocator) map[string]any {
	res := map[string]any{}
	ordered := append([]model.SRv6MyLocator{}, locators...)
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].Node < ordered[j].Node })
	rows := []map[string]any{}
	for _, loc := range ordered {
		rows = append(rows, map[string]any{
			"locator": "loc-" + loc.Node,
			"prefix":  loc.Prefix,
		})
	}
	res["/sonic-srv6:sonic-srv6/SRV6_MY_LOCATORS"] = rows
	return res
}

// RenderSRv6MySids emits SRV6_MY_SIDS rows for service decap SIDs.
// Row key format: `loc-<node>|fcbb:bbbb:<node>:<fn>::/64` with
// `action=uDT46` and `decap_vrf=<vrf>` (data-model §8.3).
func RenderSRv6MySids(sids []model.SRv6MySid) map[string]any {
	res := map[string]any{}
	ordered := append([]model.SRv6MySid{}, sids...)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].Node != ordered[j].Node {
			return ordered[i].Node < ordered[j].Node
		}
		return ordered[i].Prefix < ordered[j].Prefix
	})
	rows := []map[string]any{}
	for _, sid := range ordered {
		row := map[string]any{
			"locator": "loc-" + sid.Node,
			"sid":     sid.Prefix,
			"action":  sid.Action,
		}
		if sid.DecapVRF != "" {
			row["decap_vrf"] = sid.DecapVRF
		}
		rows = append(rows, row)
	}
	res["/sonic-srv6:sonic-srv6/SRV6_MY_SIDS"] = rows
	return res
}
