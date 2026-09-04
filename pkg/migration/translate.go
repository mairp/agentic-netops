// SPDX-License-Identifier: Apache-2.0
package migration

import (
	"fmt"
	"strings"
)

// RouteTargets models deterministic import/export ordering.
type RouteTargets struct {
	Import []string `json:"import,omitempty"`
	Export []string `json:"export,omitempty"`
}

// EVPN block under a bridge domain.
type EVPN struct {
	RouteTargets RouteTargets `json:"routeTargets,omitempty"`
}

// IRB symmetric gateway parameters rendered under a bridge domain.
type IRB struct {
	VRF       string `json:"vrf"`
	GatewayV4 string `json:"gatewayIPv4,omitempty"`
	GatewayV6 string `json:"gatewayIPv6,omitempty"`
}

// BridgeDomain rendered for VPLS/VPWS and IRB.
type BridgeDomain struct {
	Name  string `json:"name"`
	VLAN  int    `json:"vlan,omitempty"`
	L2VNI int    `json:"l2vni,omitempty"`
	EVPN  *EVPN  `json:"evpn,omitempty"`
	IRB   *IRB   `json:"irb,omitempty"`
}

// Router rendered for L3VPN and IRB VRF.
type Router struct {
	Name         string       `json:"name"`
	RD           string       `json:"rd"`
	RouteTargets RouteTargets `json:"routeTargets,omitempty"`
	L3VNI        int          `json:"l3vni,omitempty"`
	Prefixes     []string     `json:"prefixes,omitempty"`
}

// Attachment rendered in attachments list; either VLAN or VRF is set.
type Attachment struct {
	Node       string `json:"node"`
	VLAN       int    `json:"vlan,omitempty"`
	VRF        string `json:"vrf,omitempty"`
	Attachment string `json:"attachment"`
}

// NetworkSpec is ordered to produce deterministic YAML.
type NetworkSpec struct {
	Description   string         `json:"description,omitempty"`
	BridgeDomains []BridgeDomain `json:"bridgeDomains,omitempty"`
	Routers       []Router       `json:"routers,omitempty"`
	Attachments   []Attachment   `json:"attachments,omitempty"`
}

// KubenetNetwork is a minimal upstream Network shape we generate deterministically.
type KubenetNetwork struct {
	APIVersion string         `json:"apiVersion"`
	Kind       string         `json:"kind"`
	Metadata   map[string]any `json:"metadata"`
	Spec       NetworkSpec    `json:"spec"`
}

// OutputBundle captures deterministic artifacts and provenance for audit.
type OutputBundle struct {
	Translator  string            `json:"translator"`
	Version     string            `json:"version"`
	Mapping     string            `json:"mapping"`
	InputHash   string            `json:"inputHash"`
	Annotations map[string]string `json:"annotations"`
	NetworkYAML string            `json:"networkYAML"`
}

// Translate produces a Kubenet Network with deterministic fields and annotations.
// It assumes ValidateAllOrNothing has already passed for 'in'.
func Translate(in *ServiceInput) (*OutputBundle, error) {
	if in == nil {
		return nil, fmt.Errorf("nil input")
	}
	hash, err := in.CanonicalHash()
	if err != nil {
		return nil, err
	}

	name := fmt.Sprintf("migr-%s", in.ServiceID)
	metadata := map[string]any{
		"name":      name,
		"namespace": "kubenet-system",
		"annotations": map[string]string{
			"agentic-netops.io/translator":           TranslatorName,
			"agentic-netops.io/translator-version":   TranslatorVersion,
			"agentic-netops.io/mapping-version":      MappingVersion,
			"agentic-netops.io/migration-input-hash": hash,
			"agentic-netops.io/tenant":               in.Tenant,
			"agentic-netops.io/service-type":         string(in.Type),
		},
	}

	spec := NetworkSpec{Description: fmt.Sprintf("Migrated service %s (%s)", in.ServiceID, in.Type)}
	switch in.Type {
	case ServiceVPLS, ServiceVPWS:
		bd := BridgeDomain{
			Name:  fmt.Sprintf("bd-%s", in.ServiceID),
			VLAN:  endpointVLAN(in.Endpoints),
			L2VNI: in.L2VNI,
			EVPN:  &EVPN{RouteTargets: RouteTargets{Import: in.RDRT.ImportRT, Export: in.RDRT.ExportRT}},
		}
		spec.BridgeDomains = []BridgeDomain{bd}
		spec.Attachments = attachmentsForL2(in.Endpoints)
		if in.Type == ServiceVPWS {
			ann := metadata["annotations"].(map[string]string)
			ann["agentic-netops.io/limited-equivalence"] = "vpws-to-l2vni"
		}
	case ServiceL3VPN:
		r := Router{
			Name:         fmt.Sprintf("vrf-%s", in.ServiceID),
			RD:           in.RDRT.RD,
			RouteTargets: RouteTargets{Import: in.RDRT.ImportRT, Export: in.RDRT.ExportRT},
			L3VNI:        in.L3VNI,
			Prefixes:     concatPrefixes(in.AF),
		}
		spec.Routers = []Router{r}
		spec.Attachments = attachmentsForL3(in.Endpoints, r.Name)
	case ServiceIRB:
		r := Router{
			Name:         fmt.Sprintf("vrf-%s", in.ServiceID),
			RD:           in.RDRT.RD,
			RouteTargets: RouteTargets{Import: in.RDRT.ImportRT, Export: in.RDRT.ExportRT},
			L3VNI:        in.L3VNI,
		}
		// The bridge domain's irb.vrf must name a router in THIS Network, or
		// the renderer has no L3VNI to put the gateway SVI in. The intent's
		// irbGateway.vrf is a tenant-scoped label (vrf-<tenant>) and never
		// matched the per-service router the translator emits, so every IRB
		// rendered as a plain VPLS with the routed half dropped.
		bd := BridgeDomain{
			Name:  fmt.Sprintf("bd-%s", in.ServiceID),
			VLAN:  endpointVLAN(in.Endpoints),
			L2VNI: in.L2VNI,
			// The L2 half needs the service's own route targets, exactly like
			// VPLS and VPWS. Without them FRR falls back to an auto-derived
			// RD/RT per leaf — and the leaves have different eBGP ASNs, so the
			// derived targets do not match and no MAC route is ever imported
			// across the fabric (seen live: RD 10.0.0.21:16 on one leaf,
			// 10.0.0.22:12 on the other, for the same bridge domain).
			EVPN: &EVPN{RouteTargets: RouteTargets{Import: in.RDRT.ImportRT, Export: in.RDRT.ExportRT}},
			IRB:  &IRB{VRF: r.Name, GatewayV4: in.IRBGateway.GatewayV4, GatewayV6: in.IRBGateway.GatewayV6},
		}
		spec.Routers = []Router{r}
		spec.BridgeDomains = []BridgeDomain{bd}
		spec.Attachments = attachmentsForL2(in.Endpoints)
	default:
		return nil, fmt.Errorf("unsupported type: %s", in.Type)
	}

	net := KubenetNetwork{
		APIVersion: "network.kubenet.dev/v1alpha1",
		Kind:       "Network",
		Metadata:   metadata,
		Spec:       spec,
	}
	// Manually assemble YAML to achieve deterministic key order for golden tests.
	yml := buildYAML(&net)

	out := &OutputBundle{
		Translator:  TranslatorName,
		Version:     TranslatorVersion,
		Mapping:     MappingVersion,
		InputHash:   hash,
		Annotations: metadata["annotations"].(map[string]string),
		NetworkYAML: yml,
	}
	return out, nil
}

func buildYAML(n *KubenetNetwork) string {
	b := &strings.Builder{}
	fmt.Fprintf(b, "apiVersion: %s\n", n.APIVersion)
	fmt.Fprintf(b, "kind: %s\n", n.Kind)
	fmt.Fprintf(b, "metadata:\n")
	fmt.Fprintf(b, "  name: %s\n", n.Metadata["name"].(string))
	fmt.Fprintf(b, "  namespace: %s\n", n.Metadata["namespace"].(string))
	anns := n.Metadata["annotations"].(map[string]string)
	fmt.Fprintf(b, "  annotations:\n")
	// stable annotation order
	keys := []string{
		"agentic-netops.io/translator",
		"agentic-netops.io/translator-version",
		"agentic-netops.io/mapping-version",
		"agentic-netops.io/migration-input-hash",
		"agentic-netops.io/tenant",
		"agentic-netops.io/service-type",
		"agentic-netops.io/limited-equivalence",
	}
	for _, k := range keys {
		if v, ok := anns[k]; ok {
			fmt.Fprintf(b, "    %s: %s\n", k, v)
		}
	}
	fmt.Fprintf(b, "spec:\n")
	fmt.Fprintf(b, "  description: %s\n", n.Spec.Description)
	// BridgeDomains
	if len(n.Spec.BridgeDomains) > 0 {
		fmt.Fprintf(b, "  bridgeDomains:\n")
		for _, bd := range n.Spec.BridgeDomains {
			fmt.Fprintf(b, "  - name: %s\n", bd.Name)
			if bd.VLAN != 0 {
				fmt.Fprintf(b, "    vlan: %d\n", bd.VLAN)
			}
			if bd.L2VNI != 0 {
				fmt.Fprintf(b, "    l2vni: %d\n", bd.L2VNI)
			}
			if bd.EVPN != nil {
				fmt.Fprintf(b, "    evpn:\n")
				fmt.Fprintf(b, "      routeTargets:\n")
				if len(bd.EVPN.RouteTargets.Import) > 0 {
					fmt.Fprintf(b, "        import:\n")
					for _, rt := range bd.EVPN.RouteTargets.Import {
						fmt.Fprintf(b, "        - \"%s\"\n", rt)
					}
				}
				if len(bd.EVPN.RouteTargets.Export) > 0 {
					fmt.Fprintf(b, "        export:\n")
					for _, rt := range bd.EVPN.RouteTargets.Export {
						fmt.Fprintf(b, "        - \"%s\"\n", rt)
					}
				}
			}
			if bd.IRB != nil {
				fmt.Fprintf(b, "    irb:\n")
				fmt.Fprintf(b, "      vrf: %s\n", bd.IRB.VRF)
				if bd.IRB.GatewayV4 != "" {
					fmt.Fprintf(b, "      gatewayIPv4: %s\n", bd.IRB.GatewayV4)
				}
				if bd.IRB.GatewayV6 != "" {
					fmt.Fprintf(b, "      gatewayIPv6: %s\n", bd.IRB.GatewayV6)
				}
			}
		}
	}
	// Routers
	if len(n.Spec.Routers) > 0 {
		fmt.Fprintf(b, "  routers:\n")
		for _, r := range n.Spec.Routers {
			fmt.Fprintf(b, "  - name: %s\n", r.Name)
			fmt.Fprintf(b, "    rd: %s\n", r.RD)
			fmt.Fprintf(b, "    routeTargets:\n")
			if len(r.RouteTargets.Import) > 0 {
				fmt.Fprintf(b, "      import:\n")
				for _, rt := range r.RouteTargets.Import {
					fmt.Fprintf(b, "      - \"%s\"\n", rt)
				}
			}
			if len(r.RouteTargets.Export) > 0 {
				fmt.Fprintf(b, "      export:\n")
				for _, rt := range r.RouteTargets.Export {
					fmt.Fprintf(b, "      - \"%s\"\n", rt)
				}
			}
			if r.L3VNI != 0 {
				fmt.Fprintf(b, "    l3vni: %d\n", r.L3VNI)
			}
			if len(r.Prefixes) > 0 {
				fmt.Fprintf(b, "    prefixes:\n")
				for _, p := range r.Prefixes {
					fmt.Fprintf(b, "    - %s\n", p)
				}
			}
		}
	}
	// Attachments
	if len(n.Spec.Attachments) > 0 {
		fmt.Fprintf(b, "  attachments:\n")
		for _, a := range n.Spec.Attachments {
			fmt.Fprintf(b, "  - node: %s\n", a.Node)
			if a.VLAN != 0 {
				fmt.Fprintf(b, "    vlan: %d\n", a.VLAN)
			}
			if a.VRF != "" {
				fmt.Fprintf(b, "    vrf: %s\n", a.VRF)
			}
			fmt.Fprintf(b, "    attachment: %s\n", a.Attachment)
		}
	}
	return b.String()
}

func endpointVLAN(eps []Endpoint) int {
	if len(eps) == 0 {
		return 0
	}
	return eps[0].VLAN
}

func attachmentsForL2(eps []Endpoint) []Attachment {
	var out []Attachment
	for _, ep := range eps {
		out = append(out, Attachment{Node: ep.Node, VLAN: ep.VLAN, Attachment: ep.Attachment})
	}
	return out
}

func attachmentsForL3(eps []Endpoint, vrf string) []Attachment {
	var out []Attachment
	for _, ep := range eps {
		out = append(out, Attachment{Node: ep.Node, VRF: vrf, Attachment: ep.Attachment})
	}
	return out
}

func concatPrefixes(af *AddressFamilies) []string {
	var out []string
	if af == nil {
		return out
	}
	out = append(out, af.IPv4Prefixes...)
	out = append(out, af.IPv6Prefixes...)
	return out
}
