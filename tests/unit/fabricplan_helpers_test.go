// SPDX-License-Identifier: Apache-2.0
package unit

import (
	"sort"
	"strings"

	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/kubenet"
)

// srlinuxSitePorts is the site port map the SR Linux lab publishes through
// FABRIC_PORT_MAP (deploy/agentic-netops/manifests/provider.yaml). The register
// guard and the golden plans both render against it, so what they assert is
// what the provider will actually send.
func srlinuxSitePorts() fabricplan.PortMapper {
	return fabricplan.PortMapper{
		"wan1":      "ethernet-1/4",
		"ethernet1": "ethernet-1/3",
		"ethernet2": "ethernet-1/3",
		"ethernet3": "ethernet-1/3",
		"e1-1":      "ethernet-1/1",
		"e1-2":      "ethernet-1/2",
		"e1-3":      "ethernet-1/3",
		"e1-4":      "ethernet-1/4",
	}
}

// constructNetworks is the five constructs on a two-leaf site, exactly as the
// intent tier submits them. Everything in this file that claims to describe the
// renderer derives from these, so a renderer change that is not reflected in
// the register or the golden plans fails a test rather than a live apply.
func constructNetworks() map[string]*kubenet.Network {
	return map[string]*kubenet.Network{
		"vlan":    vlanConstruct(),
		"mac-vrf": macVRFConstruct(),
		"ip-vrf":  ipVRFConstruct(),
		"irb":     irbConstruct(),
		"acl":     aclConstruct(),
	}
}

func vlanConstruct() *kubenet.Network {
	return network("svc-vlan130", "acme", map[string]any{
		"vlans":       []any{map[string]any{"name": "vlan130", "vlan": float64(130)}},
		"attachments": []any{map[string]any{"node": "leaf01", "attachment": "ethernet1", "vlan": float64(130)}},
	})
}

func macVRFConstruct() *kubenet.Network {
	return network("svc-vlan150", "blue", map[string]any{
		"bridgeDomains": []any{map[string]any{
			"name": "vlan150", "vlan": float64(150), "l2vni": float64(10150),
			"evpn": map[string]any{"routeTargets": map[string]any{
				"import": []any{"65000:150"}, "export": []any{"65000:150"},
			}},
		}},
		"attachments": []any{
			map[string]any{"node": "leaf01", "attachment": "ethernet1", "vlan": float64(150)},
			map[string]any{"node": "leaf02", "attachment": "ethernet1", "vlan": float64(150)},
		},
	})
}

func ipVRFConstruct() *kubenet.Network {
	return network("svc-ipvrf", "initech", map[string]any{
		"routers": []any{map[string]any{
			"name": "vrf-initech01", "l3vni": float64(10018), "rd": "65000:18",
			"routeTargets": map[string]any{"import": []any{"65000:18"}, "export": []any{"65000:18"}},
			"prefixes":     []any{"10.50.0.0/24"},
		}},
		"attachments": []any{
			map[string]any{"node": "leaf01", "attachment": "wan1", "vrf": "vrf-initech01"},
			map[string]any{"node": "leaf02", "attachment": "wan1", "vrf": "vrf-initech01"},
		},
	})
}

func irbConstruct() *kubenet.Network {
	return network("svc-irb200", "green", map[string]any{
		"bridgeDomains": []any{map[string]any{
			"name": "vlan200", "vlan": float64(200), "l2vni": float64(10200),
			"evpn": map[string]any{"routeTargets": map[string]any{"export": []any{"65000:200"}}},
			"irb":  map[string]any{"vrf": "vrf-green01", "gatewayIPv4": "10.60.0.1/24", "gatewayIPv6": "fd00:60::1/64"},
		}},
		"routers": []any{map[string]any{
			"name": "vrf-green01", "l3vni": float64(10020), "rd": "65000:20",
			"routeTargets": map[string]any{"import": []any{"65000:20"}, "export": []any{"65000:20"}},
		}},
		"attachments": []any{
			map[string]any{"node": "leaf01", "attachment": "ethernet1", "vlan": float64(200)},
			map[string]any{"node": "leaf02", "attachment": "ethernet1", "vlan": float64(200)},
		},
	})
}

func aclConstruct() *kubenet.Network {
	return network("svc-acl", "acme", map[string]any{
		"accessLists": []any{map[string]any{
			"name": "allow-web", "stage": "ingress", "type": "l3", "defaultAction": "deny",
			"rules": []any{map[string]any{
				"name": "allow-https", "priority": float64(100), "action": "permit",
				"protocol": "tcp", "sourcePrefix": "10.0.0.0/24", "destinationPort": "443",
				"description": "tenant web",
			}},
		}},
		"attachments": []any{map[string]any{"node": "leaf02", "attachment": "wan1"}},
	})
}

func network(name, namespace string, spec map[string]any) *kubenet.Network {
	n := &kubenet.Network{Spec: spec}
	n.Name = name
	n.Namespace = namespace
	return n
}

// pathFamily reduces one rendered gNMI path to the family the register records:
// the element names with their key predicates removed. Keys are per-service
// values (a vlan id, an interface name, a filter name); the family is the
// device surface the renderer writes to, and that is what a register can
// meaningfully cover.
func pathFamily(p string) string {
	var out []string
	depth := 0
	var cur strings.Builder
	flush := func() {
		if cur.Len() > 0 {
			out = append(out, cur.String())
			cur.Reset()
		}
	}
	for _, r := range strings.TrimPrefix(p, "/") {
		switch {
		case r == '[':
			depth++
		case r == ']':
			if depth > 0 {
				depth--
			}
		case depth > 0:
			// inside a key predicate: part of the instance, not the family
		case r == '/':
			flush()
		default:
			cur.WriteRune(r)
		}
	}
	flush()
	return "/" + strings.Join(out, "/")
}

// renderedPathFamilies renders every construct and returns each distinct path
// family the plans touch — apply ops, rollback ops and verification checks
// alike. A read the executor performs is as much a dependency on the device
// model as a write, so both belong in the register.
func renderedPathFamilies() (map[string]any, error) {
	families := map[string]any{}
	for name, net := range constructNetworks() {
		plan, err := fabricplan.ForNetwork(net, fabricplan.Options{Ports: srlinuxSitePorts(), VXLANTunnel: "vxlan1"})
		if err != nil {
			return nil, err
		}
		for _, np := range plan.Nodes {
			for _, op := range append(append([]fabricplan.Op{}, np.Ops...), np.Rollback...) {
				if op.GNMI == nil {
					continue
				}
				for _, u := range op.GNMI.Updates {
					families[pathFamily(u.Path)] = name
				}
				for _, d := range op.GNMI.Deletes {
					families[pathFamily(d)] = name
				}
			}
			for _, c := range np.Checks {
				families[pathFamily(c.Path)] = name
			}
		}
	}
	return families, nil
}

func sortedKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
