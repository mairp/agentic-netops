// SPDX-License-Identifier: Apache-2.0
package migration

import (
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// The construct vocabulary.
//
// The tier used to advertise service-provider service names — VPLS, VPWS,
// L3VPN, L2L3-IRB. The fabric underneath them is a datacenter EVPN/VXLAN
// fabric running SONiC, and SONiC has no notion of any of those: it has
// VLANs, VRFs, VXLAN tunnel maps and ACLs. The operator vocabulary is now the
// datacenter one, taken from the four SONiC construct references:
//
//	vlan     https://developer.cisco.com/docs/sonic/vlan/
//	mac-vrf  https://developer.cisco.com/docs/sonic/vxlan-evpn/
//	ip-vrf   https://developer.cisco.com/docs/sonic/vrf/
//	acl      https://developer.cisco.com/docs/sonic/acl/
//
// Four constructs, and the compositions between them, cover what this fabric
// can express:
//
//	vlan     a local broadcast domain: a VLAN and the ports in it. No VNI, no
//	         EVPN, no route targets — it does not leave the node.
//	mac-vrf  a VLAN extended over the fabric by an L2VNI, imported and
//	         exported by EVPN route targets (RT-2/RT-3). Two attachments make
//	         it point to point; more make it multipoint; neither is a
//	         different construct.
//	ip-vrf   a routed instance: a VRF with an L3VNI and route targets,
//	         advertising its prefixes as EVPN RT-5.
//	acl      a filter bound to the ports a service attaches on. It is a
//	         construct in its own right and also a property any other
//	         construct may carry.
//
// Symmetric IRB is not a fifth type — it is a mac-vrf that carries an anycast
// gateway into an ip-vrf, which is exactly how the fabric renders it.
//
// The service-provider names remain accepted as INPUT aliases: feature 001 is
// a migration translator whose sources are brownfield MPLS VPN services, and
// refusing to read their own vocabulary would defeat it. They are folded to
// the constructs above on entry, so everything past ParseStrictBatch — the
// validator, the translator, the rendered Network, the annotations, the audit
// trail — speaks one vocabulary.
const (
	// ServiceVLAN is a local VLAN: VLAN row and port membership, nothing else.
	ServiceVLAN ServiceType = "vlan"
	// ServiceMACVRF is an EVPN L2 instance (L2VNI + RD/RT), optionally with an
	// anycast gateway, which makes it a symmetric-IRB service.
	ServiceMACVRF ServiceType = "mac-vrf"
	// ServiceIPVRF is an EVPN L3 instance (VRF + L3VNI + RD/RT).
	ServiceIPVRF ServiceType = "ip-vrf"
	// ServiceACL is a standalone filter bound to the named attachment ports.
	ServiceACL ServiceType = "acl"

	// Legacy service-provider constants kept for backwards-compatible callers and tests.
	// They are accepted as inputs and folded to the construct vocabulary by Canonicalize.
	ServiceVPLS  ServiceType = LegacyVPLS
	ServiceVPWS  ServiceType = LegacyVPWS
	ServiceL3VPN ServiceType = LegacyL3VPN
	ServiceIRB   ServiceType = LegacyIRB
)

// Legacy service-provider type literals, accepted on input and folded to a
// construct by Canonicalize. They are never emitted.
const (
	LegacyVPLS  ServiceType = "VPLS"
	LegacyVPWS  ServiceType = "VPWS"
	LegacyL3VPN ServiceType = "L3VPN"
	LegacyIRB   ServiceType = "L2L3-IRB"
)

// Constructs lists the vocabulary in the order it is reported to an operator.
func Constructs() []ServiceType {
	return []ServiceType{ServiceVLAN, ServiceMACVRF, ServiceIPVRF, ServiceACL}
}

// ConstructList renders Constructs() for an error message.
func ConstructList() string {
	names := make([]string, 0, 4)
	for _, c := range Constructs() {
		names = append(names, string(c))
	}
	return strings.Join(names, ", ")
}

// typeKey folds case and separators so `ip-vrf`, `IP_VRF`, `ipVrf` and `IPVRF`
// are one type. An operator (or an LLM writing the operator's request down)
// should not be able to miss the construct on punctuation.
func typeKey(t ServiceType) string {
	var b strings.Builder
	for _, r := range strings.ToLower(string(t)) {
		if r == '-' || r == '_' || r == ' ' || r == '.' || r == '+' {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// canonicalTypes maps every accepted spelling — construct and legacy alias —
// onto the canonical construct it names.
var canonicalTypes = map[string]ServiceType{
	"vlan":       ServiceVLAN,
	"macvrf":     ServiceMACVRF,
	"l2vni":      ServiceMACVRF,
	"ipvrf":      ServiceIPVRF,
	"l3vni":      ServiceIPVRF,
	"acl":        ServiceACL,
	"accesslist": ServiceACL,

	// Service-provider input aliases (feature 001 migration sources).
	"vpls":    ServiceMACVRF,
	"vpws":    ServiceMACVRF,
	"eline":   ServiceMACVRF,
	"l3vpn":   ServiceIPVRF,
	"l2l3irb": ServiceMACVRF,
	"irb":     ServiceMACVRF,
}

// legacyTypes are the spellings that carry feature-001 semantics beyond the
// construct they fold to (VPWS's exact endpoint count and its explicit
// limited-equivalence opt-in; IRB's gateway block).
var legacyTypes = map[string]ServiceType{
	"vpls":    LegacyVPLS,
	"vpws":    LegacyVPWS,
	"eline":   LegacyVPWS,
	"l3vpn":   LegacyL3VPN,
	"l2l3irb": LegacyIRB,
	"irb":     LegacyIRB,
}

// AnycastGateway is the routed half of a mac-vrf: the distributed anycast
// gateway the bridge domain's SVI carries, and the ip-vrf it lives in. Its
// presence is what makes a mac-vrf a symmetric-IRB service.
type AnycastGateway struct {
	// IPVRF names the routed instance this gateway belongs to. The translator
	// emits one ip-vrf per service and points the gateway at it; the field is
	// carried so an operator can say which instance they meant.
	IPVRF     string `json:"ipVrf,omitempty"`
	GatewayV4 string `json:"gatewayIPv4,omitempty"`
	GatewayV6 string `json:"gatewayIPv6,omitempty"`
}

// ACLRule is one match/action row of an access list (SONiC ACL_RULE).
//
// Field names follow the operator vocabulary; the CONFIG_DB field names they
// render to (SRC_IP, L4_DST_PORT, PACKET_ACTION, ...) are applied by the
// fabric planner, not here.
type ACLRule struct {
	// Name is the rule id within the table. Required and unique per ACL.
	Name string `json:"name"`
	// Priority orders evaluation; higher wins. 1-65535.
	Priority int `json:"priority"`
	// Action is permit or deny (rendered FORWARD / DROP).
	Action string `json:"action"`
	// Protocol is tcp, udp, icmp, igmp, rsvp, gre, ah, pim, l2tp, any, or a numeric IP protocol.
	Protocol string `json:"protocol,omitempty"`
	// SourcePrefix / DestinationPrefix are CIDR prefixes matching the address
	// family of the ACL type.
	SourcePrefix      string `json:"sourcePrefix,omitempty"`
	DestinationPrefix string `json:"destinationPrefix,omitempty"`
	// SourcePort / DestinationPort are an L4 port or an inclusive `lo-hi`
	// range. Only meaningful for tcp/udp.
	SourcePort      string `json:"sourcePort,omitempty"`
	DestinationPort string `json:"destinationPort,omitempty"`
	// Description is carried into the rendered row for the operator's benefit.
	Description string `json:"description,omitempty"`
}

// ACL is an access list: a stage, an address family, and an ordered set of
// rules. It is bound to the ports of the endpoints the service names.
type ACL struct {
	// Name is the operator's name for the list. Defaulted from the service id.
	Name string `json:"name,omitempty"`
	// Stage is ingress or egress.
	Stage string `json:"stage"`
	// Type is l3 (IPv4) or l3v6 (IPv6).
	Type string `json:"type"`
	// Rules is the ordered match/action set; at least one is required.
	Rules []ACLRule `json:"rules"`
	// DefaultAction, when set, appends a terminal lowest-priority rule so the
	// list's behaviour for unmatched traffic is declared rather than implied.
	DefaultAction string `json:"defaultAction,omitempty"`
	// BindTo scopes the binding target. Only "port" is accepted; anything else
	// is refused with a cause stating the list binds to ports.
	BindTo string `json:"bindTo,omitempty"`
}

// ACL vocabulary accepted on input, folded to the canonical spelling.
var (
	aclStages = map[string]string{
		"ingress": "ingress", "in": "ingress", "inbound": "ingress",
		"egress": "egress", "out": "egress", "outbound": "egress",
	}
	aclTypes = map[string]string{
		"l3": "l3", "ipv4": "l3", "ip": "l3",
		"l3v6": "l3v6", "ipv6": "l3v6", "l3ipv6": "l3v6",
	}
	aclActions = map[string]string{
		"permit": "permit", "allow": "permit", "forward": "permit", "accept": "permit",
		"deny": "deny", "drop": "deny", "block": "deny", "discard": "deny",
	}
	aclProtocols = map[string]string{
		"any": "any", "": "any",
		"tcp": "tcp", "udp": "udp", "icmp": "icmp",
		"igmp": "igmp", "rsvp": "rsvp", "gre": "gre", "ah": "ah", "pim": "pim", "l2tp": "l2tp",
	}
)

func foldWord(s string) string { return strings.ToLower(strings.TrimSpace(s)) }

// Canonicalize folds an input's vocabulary onto the constructs before anything
// else looks at it: type aliases, the legacy irbGateway block, and the ACL's
// own stage/type/action words. It is called by ParseStrictBatch, so the
// validator and the translator only ever see canonical values.
//
// The canonical form is also what CanonicalHash covers, so the same service
// expressed in either vocabulary hashes identically.
func (in *ServiceInput) Canonicalize() {
	if in == nil {
		return
	}
	key := typeKey(in.Type)
	if legacy, ok := legacyTypes[key]; ok {
		in.SourceType = legacy
	}
	if canonical, ok := canonicalTypes[key]; ok {
		in.Type = canonical
	}

	// The legacy IRB gateway block is the anycast gateway under its old name.
	// Its `vrf` was a tenant-scoped label that never named the router the
	// translator emitted; the ip-vrf is resolved at translation time either
	// way, so only the addresses carry over.
	if in.IRBGateway != nil {
		if in.AnycastGateway == nil {
			// Only the addresses carry over: the legacy `vrf` label named no
			// router the translator emits, and the ip-vrf is resolved at
			// translation time as one per-service router either way.
			in.AnycastGateway = &AnycastGateway{
				GatewayV4: in.IRBGateway.GatewayV4,
				GatewayV6: in.IRBGateway.GatewayV6,
			}
		}
		in.IRBGateway = nil
	}

	if in.ACL != nil {
		a := in.ACL
		if v, ok := aclStages[foldWord(a.Stage)]; ok {
			a.Stage = v
		}
		if v, ok := aclTypes[typeKey(ServiceType(a.Type))]; ok {
			a.Type = v
		}
		if v, ok := aclActions[foldWord(a.DefaultAction)]; ok && a.DefaultAction != "" {
			a.DefaultAction = v
		}
		for i := range a.Rules {
			if v, ok := aclActions[foldWord(a.Rules[i].Action)]; ok {
				a.Rules[i].Action = v
			}
			if v, ok := aclProtocols[foldWord(a.Rules[i].Protocol)]; ok {
				a.Rules[i].Protocol = v
			}
		}
	}
}

// aclCauses validates an access list. Every cause names the property, in the
// same all-or-nothing style as the rest of the contract.
func aclCauses(a *ACL) []string {
	var causes []string
	if _, ok := aclStages[foldWord(a.Stage)]; !ok {
		causes = append(causes, fmt.Sprintf("acl.stage: required, one of ingress, egress (got %q)", a.Stage))
	}
	if a.BindTo != "" && a.BindTo != "port" {
		causes = append(causes, fmt.Sprintf("acl.bindTo: %q is unsupported; an access list binds to ports", a.BindTo))
	}
	if _, ok := aclTypes[typeKey(ServiceType(a.Type))]; !ok {
		causes = append(causes, fmt.Sprintf("acl.type: required, one of l3, l3v6 (got %q)", a.Type))
	}
	if a.DefaultAction != "" {
		if _, ok := aclActions[foldWord(a.DefaultAction)]; !ok {
			causes = append(causes, fmt.Sprintf("acl.defaultAction: one of permit, deny (got %q)", a.DefaultAction))
		}
	}
	if len(a.Rules) == 0 {
		causes = append(causes, "acl.rules: at least one rule is required")
		if a.Name != "" {
			causes = append(causes, "acl: a service carries its own rules and its name is a label; provide rules instead of referencing by name")
		}
	}
	seenName := map[string]bool{}
	seenPriority := map[int]bool{}
	for i, r := range a.Rules {
		if r.Name == "" {
			causes = append(causes, fmt.Sprintf("acl.rules[%d].name: required", i))
		} else if seenName[r.Name] {
			causes = append(causes, fmt.Sprintf("acl.rules[%d].name: duplicate rule name %q", i, r.Name))
		} else {
			seenName[r.Name] = true
		}
		if r.Priority == 1 {
			causes = append(causes, fmt.Sprintf("acl.rules[%d].priority: 1 is reserved for the default action; usable priorities are 2-65535", i))
		} else if r.Priority < 2 || r.Priority > 65535 {
			causes = append(causes, fmt.Sprintf("acl.rules[%d].priority: must be 2-65535 (got %d)", i, r.Priority))
		} else if seenPriority[r.Priority] {
			// Two rules at one priority make evaluation order undefined, and
			// which of a permit and a deny wins is exactly what an operator
			// cannot afford to have decided arbitrarily.
			causes = append(causes, fmt.Sprintf("acl.rules[%d].priority: %d is already used by another rule; priorities must be distinct", i, r.Priority))
		} else {
			seenPriority[r.Priority] = true
		}
		if _, ok := aclActions[foldWord(r.Action)]; !ok {
			causes = append(causes, fmt.Sprintf("acl.rules[%d].action: required, one of permit, deny (got %q)", i, r.Action))
		}
		if _, ok := aclProtocols[foldWord(r.Protocol)]; !ok {
			if n, err := strconv.Atoi(r.Protocol); err != nil || n < 0 || n > 255 {
				causes = append(causes, fmt.Sprintf(
					"acl.rules[%d].protocol: one of any, tcp, udp, icmp, igmp, rsvp, gre, ah, pim, l2tp or an IP protocol number 0-255 (got %q)", i, r.Protocol))
			}
		}
		causes = append(causes, aclPrefixCauses(i, "sourcePrefix", r.SourcePrefix, a.Type)...)
		causes = append(causes, aclPrefixCauses(i, "destinationPrefix", r.DestinationPrefix, a.Type)...)
		causes = append(causes, aclPortCauses(i, "sourcePort", r.SourcePort, r.Protocol)...)
		causes = append(causes, aclPortCauses(i, "destinationPort", r.DestinationPort, r.Protocol)...)
	}
	return causes
}

// aclPrefixCauses rejects a prefix that is malformed or in the wrong family
// for the list. A v6 prefix in an l3 (IPv4) table renders a row the ASIC will
// never match — a silently dead rule in a filter is worse than a rejection.
func aclPrefixCauses(i int, field, prefix, aclType string) []string {
	if prefix == "" {
		return nil
	}
	p, err := netip.ParsePrefix(prefix)
	if err != nil {
		return []string{fmt.Sprintf("acl.rules[%d].%s: not a CIDR prefix (%q)", i, field, prefix)}
	}
	switch aclTypes[typeKey(ServiceType(aclType))] {
	case "l3":
		if !p.Addr().Is4() {
			return []string{fmt.Sprintf("acl.rules[%d].%s: %s is IPv6 but the acl type is l3 (IPv4); use type l3v6", i, field, prefix)}
		}
	case "l3v6":
		if p.Addr().Is4() {
			return []string{fmt.Sprintf("acl.rules[%d].%s: %s is IPv4 but the acl type is l3v6; use type l3", i, field, prefix)}
		}
	}
	return nil
}

// aclPortCauses rejects an L4 port on a rule whose protocol has none, and any
// port or range outside 0-65535.

func aclPortCauses(i int, field, port, protocol string) []string {
	if port == "" {
		return nil
	}
	switch aclProtocols[foldWord(protocol)] {
	case "tcp", "udp":
	default:
		return []string{fmt.Sprintf(
			"acl.rules[%d].%s: L4 ports require protocol tcp or udp (got %q)", i, field, protocol)}
	}
	lo, hi, isRange := strings.Cut(port, "-")
	loN, err := strconv.Atoi(strings.TrimSpace(lo))
	if err != nil || loN < 0 || loN > 65535 {
		return []string{fmt.Sprintf("acl.rules[%d].%s: not a port in 0-65535 (%q)", i, field, port)}
	}
	if !isRange {
		return nil
	}
	hiN, err := strconv.Atoi(strings.TrimSpace(hi))
	if err != nil || hiN < 0 || hiN > 65535 {
		return []string{fmt.Sprintf("acl.rules[%d].%s: not a port range in 0-65535 (%q)", i, field, port)}
	}
	if hiN < loN {
		return []string{fmt.Sprintf("acl.rules[%d].%s: range %q ends below where it starts", i, field, port)}
	}
	return nil
}
