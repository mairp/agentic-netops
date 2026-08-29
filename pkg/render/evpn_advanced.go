// SPDX-License-Identifier: Apache-2.0
package render

import (
	"sort"

	"github.com/mairp/ainetops/pkg/model"
)

// RenderL3VNI renders a VRF-bound L3VNI association.
func RenderL3VNI(vrf model.NetworkInstance, vni int) map[string]any {
	res := map[string]any{}
	base := "/network-instances/network-instance/l3vni"
	res[base] = map[string]any{"name": vrf.Name, "vni": vni}
	return res
}

// RenderEVPNType5 renders a placeholder Type-5 route-family enablement for a VRF.
func RenderEVPNType5(vrf model.NetworkInstance) map[string]any {
	res := map[string]any{}
	base := "/network-instances/network-instance/evpn/type5"
	res[base] = map[string]any{"name": vrf.Name, "enabled": true}
	return res
}

// RenderIRB renders symmetric IRB parameters for a bridge-to-VRF gateway.
func RenderIRB(vrf model.NetworkInstance, vlan int, irb model.IRB) map[string]any {
	res := map[string]any{}
	base := "/network-instances/network-instance/bridges/irb"
	res[base] = map[string]any{
		"vrf": vrf.Name,
		"vlan": vlan,
		"gateway": map[string]any{"ipv4": irb.GatewayIPv4, "ipv6": irb.GatewayIPv6},
	}
	return res
}

// RenderSRv6Behaviors renders SRv6 behaviors including H.Encaps.Red, End, and End.DT46.
func RenderSRv6Behaviors(behaviors []string) map[string]any {
	res := map[string]any{}
	list := append([]string{}, behaviors...)
	sort.Strings(list)
	res["/sonic-srv6:sonic-srv6/BEHAVIORS"] = list
	return res
}

// RenderSIDList renders an ordered SID list for steering.
func RenderSIDList(name string, sids []string) map[string]any {
	res := map[string]any{}
	ordered := append([]string{}, sids...)
	res["/sonic-srv6:sonic-srv6/SID_LIST"] = []map[string]any{{"name": name, "sids": ordered}}
	return res
}

// RenderSRPolicy renders a steering policy referencing a SID list.
func RenderSRPolicy(pol model.SRPolicy) map[string]any {
	res := map[string]any{}
	res["/sonic-srv6:sonic-srv6/POLICY"] = []map[string]any{{
		"name": pol.Name,
		"selector": pol.Selector,
		"sid-list": pol.SIDListRef,
	}}
	return res
}
