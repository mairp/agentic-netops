// SPDX-License-Identifier: Apache-2.0
package render

import (
	"github.com/mairp/agentic-netops/pkg/model"
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
		"vrf":     vrf.Name,
		"vlan":    vlan,
		"gateway": map[string]any{"ipv4": irb.GatewayIPv4, "ipv6": irb.GatewayIPv6},
	}
	return res
}
