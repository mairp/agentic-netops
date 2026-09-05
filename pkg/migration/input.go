// SPDX-License-Identifier: Apache-2.0
// Package migration provides a deterministic translator from normalized MPLS VPN
// service intent into Kubenet Network resources for an EVPN/VXLAN fabric.
// It enforces an all-or-nothing validation contract and never accepts raw CLI.
package migration

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
)

// Version constants for deterministic provenance.
const (
	TranslatorName    = "agentic-netops-migration-translator"
	TranslatorVersion = "v0.1.0"
	MappingVersion    = "v0.1.0"
)

// ServiceType names one of the fabric constructs an intent may ask for. The
// vocabulary, the accepted legacy aliases and the folding between them live in
// constructs.go.
type ServiceType string

// AddressFamilies captures AFI-specific properties for an ip-vrf.
type AddressFamilies struct {
	IPv4Prefixes []string `json:"ipv4Prefixes,omitempty"`
	IPv6Prefixes []string `json:"ipv6Prefixes,omitempty"`
}

// RdRt are required route distinguisher and route-targets for VPNs.
type RdRt struct {
	RD       string   `json:"rd"`
	ImportRT []string `json:"importRT"`
	ExportRT []string `json:"exportRT"`
}

// Endpoint describes one attachment point on a target node with VLAN or VRF context.
type Endpoint struct {
	Node       string `json:"node"`           // required leaf name
	Attachment string `json:"attachment"`     // human-readable peer/endpoint id
	VLAN       int    `json:"vlan,omitempty"` // for L2 services
	VRF        string `json:"vrf,omitempty"`  // for L3/IRB attachments
}

// IRBGateway is the legacy spelling of AnycastGateway, kept so a feature-001
// migration source that still says irbGateway parses. Canonicalize folds it
// into AnycastGateway and clears it; nothing downstream reads it.
type IRBGateway struct {
	VRF       string `json:"vrf"`
	GatewayV4 string `json:"gatewayIPv4"`
	GatewayV6 string `json:"gatewayIPv6"`
}

// Policies are explicit allow-listed options.
type Policies struct {
	// VPWSLimitedEquivalence must be true to allow VPWS-to-L2VNI mapping.
	VPWSLimitedEquivalence bool `json:"vpwsLimitedEquivalence,omitempty"`
}

// UnsupportedClaims declare source-only features that must be rejected (FR-011).
// Presence of any field here causes a terminal validation failure with details.
type UnsupportedClaims struct {
	TEPolicy      any `json:"tePolicy,omitempty"`
	PseudowireOAM any `json:"pseudowireOAM,omitempty"`
	ControlWord   any `json:"controlWord,omitempty"`
	MulticastVPN  any `json:"multicastVPN,omitempty"`
	ComplexQoS    any `json:"complexQoS,omitempty"`
	ServiceChain  any `json:"serviceChain,omitempty"`
	RawCLI        any `json:"rawCLI,omitempty"`
}

// ServiceInput is the strict normalized migration input schema.
// Raw CLI is explicitly forbidden; unknown fields cause validation failure.
// Deterministic translation requires RD/RT and VNI inputs to be explicit.
type ServiceInput struct {
	// Identity
	ServiceID string      `json:"serviceId"`
	Type      ServiceType `json:"type"` // vlan | mac-vrf | ip-vrf | acl
	Tenant    string      `json:"tenant"`

	// SourceType records the legacy service-provider type the request arrived
	// as, when it arrived as one. It is provenance for the audit trail and for
	// the two feature-001 rules that outlive the rename (VPWS's exact endpoint
	// count and its limited-equivalence opt-in). It is never serialized, so the
	// same service hashes identically in either vocabulary.
	SourceType ServiceType `json:"-"`

	// VPN properties
	RDRT  *RdRt            `json:"rdRt,omitempty"`
	L2VNI int              `json:"l2vni,omitempty"` // the mac-vrf's L2VNI
	L3VNI int              `json:"l3vni,omitempty"` // the ip-vrf's L3VNI
	AF    *AddressFamilies `json:"addressFamilies,omitempty"`

	// AnycastGateway makes a mac-vrf a symmetric-IRB service: the bridge
	// domain's SVI carries the gateway inside the service's ip-vrf.
	AnycastGateway *AnycastGateway `json:"anycastGateway,omitempty"`

	// IRBGateway is the legacy spelling of the above, folded by Canonicalize.
	IRBGateway *IRBGateway `json:"irbGateway,omitempty"`

	// ACL is the filter this service carries. On a `type: acl` service it is
	// the whole service; on any other construct it is bound to the same
	// attachment ports the service lands on.
	ACL *ACL `json:"acl,omitempty"`

	// Endpoints
	Endpoints []Endpoint `json:"endpoints"`

	// Explicit policy opt-ins
	Policies Policies `json:"policies,omitempty"`

	// Explicitly modeled unsupported features — any presence rejects the request.
	Unsupported UnsupportedClaims `json:"unsupported,omitempty"`
}

// CanonicalHash returns a deterministic SHA256 over the normalized input.
func (in *ServiceInput) CanonicalHash() (string, error) {
	if in == nil {
		return "", errors.New("nil input")
	}
	// Marshal the typed struct (no maps) to stable JSON and hash it.
	b, err := json.Marshal(in)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

// ValidateAllOrNothing enforces the FR-011 contract and returns an error with
// structured causes; it does not modify input and does not perform allocation.
type ValidationError struct {
	Causes []string `json:"causes"`
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("validation failed: %v", e.Causes)
}

// ValidateAllOrNothing performs strict validation, including:
// - required fields by type;
// - explicit opt-ins for limited equivalence;
// - absent endpoints and count mismatches;
// - presence of unsupported claims;
// - collisions detected by the caller across a batch (detected via index arg).
func (in *ServiceInput) ValidateAllOrNothing(batchIndex int, dupServiceID bool) error {
	// Fold legacy and alias vocabulary to canonical constructs and words so
	// validation and translation see a single shape even when callers build the
	// struct directly (tests do) instead of using ParseStrictBatch.
	in.Canonicalize()
	var causes []string
	if in.ServiceID == "" {
		causes = append(causes, "serviceId: required")
	}
	if in.Tenant == "" {
		causes = append(causes, "tenant: required")
	}
	if in.Type == "" {
		causes = append(causes, "type: required")
	}
	if dupServiceID {
		causes = append(causes, fmt.Sprintf("collision: duplicate serviceId '%s' in batch", in.ServiceID))
	}
	// Unsupported claims
	u := in.Unsupported
	if u.TEPolicy != nil {
		causes = append(causes, "unsupported: tePolicy")
	}
	if u.PseudowireOAM != nil {
		causes = append(causes, "unsupported: pseudowireOAM")
	}
	if u.ControlWord != nil {
		causes = append(causes, "unsupported: controlWord")
	}
	if u.MulticastVPN != nil {
		causes = append(causes, "unsupported: multicastVPN")
	}
	if u.ComplexQoS != nil {
		causes = append(causes, "unsupported: complexQoS")
	}
	if u.ServiceChain != nil {
		causes = append(causes, "unsupported: serviceChain")
	}
	if u.RawCLI != nil {
		causes = append(causes, "unsupported: rawCLI")
	}

	// Endpoints basics
	if len(in.Endpoints) == 0 {
		causes = append(causes, "endpoints: at least one endpoint is required")
	}

	switch in.Type {
	case ServiceVLAN:
		// A local VLAN is the one construct with no overlay at all. Anything
		// that only means something in the overlay is a sign the operator
		// wanted a mac-vrf or an ip-vrf, so it is named rather than ignored.
		if in.L2VNI != 0 {
			causes = append(causes, "l2vni: a vlan is local to the node; ask for a mac-vrf to extend it over the fabric")
		}
		if in.L3VNI != 0 {
			causes = append(causes, "l3vni: a vlan carries no routed instance; ask for an ip-vrf, or a mac-vrf with an anycastGateway")
		}
		if in.RDRT != nil {
			causes = append(causes, "rdRt: a vlan is not advertised by EVPN and has no route distinguisher or targets")
		}
		if in.AnycastGateway != nil {
			causes = append(causes, "anycastGateway: only a mac-vrf carries an anycast gateway")
		}
		if len(in.Endpoints) < 1 {
			causes = append(causes, "endpoints: vlan requires >=1 endpoint")
		}
		causes = append(causes, endpointVLANCauses(in.Endpoints, "vlan")...)
		// Reserved VLAN band 4001-4094 is used for derived L3VLANs; refuse here with usable range.
		for i, ep := range in.Endpoints {
			if ep.VLAN > 4000 {
				causes = append(causes, fmt.Sprintf("endpoints[%d].vlan: %d is reserved (4001-4094); usable range is 1-4000", i, ep.VLAN))
			}
		}

	case ServiceMACVRF:
		if in.L2VNI == 0 {
			causes = append(causes, "l2vni: required for mac-vrf")
		}
		if in.RDRT == nil {
			causes = append(causes, "rdRt: required for mac-vrf")
		}
		// A mac-vrf that terminates a gateway is useful on a single leaf; one
		// that only bridges needs somewhere to bridge to.
		minEndpoints := 2
		// Reserved VLAN band 4001-4094 applies to mac-vrf too
		for i, ep := range in.Endpoints {
			if ep.VLAN > 4000 {
				causes = append(causes, fmt.Sprintf("endpoints[%d].vlan: %d is reserved (4001-4094); usable range is 1-4000", i, ep.VLAN))
			}
		}

		if in.AnycastGateway != nil {
			minEndpoints = 1
		}
		if len(in.Endpoints) < minEndpoints {
			causes = append(causes, fmt.Sprintf("endpoints: mac-vrf requires >=%d endpoints", minEndpoints))
		}
		causes = append(causes, endpointVLANCauses(in.Endpoints, "mac-vrf")...)
		if in.AnycastGateway != nil {
			// Symmetric IRB: the bridge domain's SVI is the gateway and lives
			// in the service's own ip-vrf, which needs its own L3VNI.
			if in.L3VNI == 0 {
				causes = append(causes, "l3vni: required for a mac-vrf with an anycastGateway (the ip-vrf it routes into)")
			}
			causes = append(causes, l3vniRenderableCauses(in.L3VNI)...)
			// At least one address family, not both. Requiring both forced
			// every gateway to carry an IPv6 address whether or not the
			// operator asked for IPv6 — an unrequested address family on the
			// SVI and a Type-5 route the service was then held to.
			if in.AnycastGateway.GatewayV4 == "" && in.AnycastGateway.GatewayV6 == "" {
				causes = append(causes, "anycastGateway: at least one of gatewayIPv4/gatewayIPv6 is required")
			}
		} else if in.L3VNI != 0 {
			causes = append(causes, "l3vni: a mac-vrf carries an L3VNI only when it declares an anycastGateway")
		}
		// Feature-001 rules that belong to the VPWS alias, not to the
		// construct: a pseudowire is exactly two attachments, and mapping one
		// onto an L2VNI is a limited equivalence the source has to opt into.
		// Asking for a mac-vrf directly claims no pseudowire and needs neither.
		if in.SourceType == LegacyVPWS {
			if len(in.Endpoints) != 2 {
				causes = append(causes, "endpoints: VPWS requires exactly 2 endpoints")
			}
			if !in.Policies.VPWSLimitedEquivalence {
				causes = append(causes, "policy: vpwsLimitedEquivalence must be true to allow limited equivalence mapping")
			}
		}
	case ServiceIPVRF:
		if in.L3VNI == 0 {
			causes = append(causes, "l3vni: required for ip-vrf")
		}
		causes = append(causes, l3vniRenderableCauses(in.L3VNI)...)
		if in.RDRT == nil {
			causes = append(causes, "rdRt: required for ip-vrf")
		}
		if in.AF == nil || (len(in.AF.IPv4Prefixes) == 0 && len(in.AF.IPv6Prefixes) == 0) {
			causes = append(causes, "addressFamilies: at least one prefix is required for ip-vrf")
		}
		if in.L2VNI != 0 {
			causes = append(causes, "l2vni: an ip-vrf carries no bridge domain; ask for a mac-vrf with an anycastGateway to get both")
		}
		if in.AnycastGateway != nil {
			causes = append(causes, "anycastGateway: belongs to the mac-vrf whose SVI carries it, not to the ip-vrf")
		}
		if len(in.Endpoints) < 1 {
			causes = append(causes, "endpoints: ip-vrf requires >=1 endpoint")
		}
		for i, ep := range in.Endpoints {
			if ep.VRF == "" {
				causes = append(causes, fmt.Sprintf("endpoints[%d].vrf: required for ip-vrf", i))
			}
		}
	case ServiceACL:
		// A standalone filter: the endpoints are the ports it binds to and
		// nothing about an overlay applies.
		if in.ACL == nil {
			causes = append(causes, "acl: required for an acl service")
		}
		if in.L2VNI != 0 || in.L3VNI != 0 || in.RDRT != nil || in.AnycastGateway != nil {
			causes = append(causes, "acl: an acl binds to ports and carries no VNI, route targets or gateway; attach it to a vlan, mac-vrf or ip-vrf to filter that service")
		}
		if len(in.Endpoints) < 1 {
			causes = append(causes, "endpoints: acl requires >=1 endpoint to bind to")
		}
	default:
		causes = append(causes, fmt.Sprintf("type: unsupported '%s' (constructs: %s)", in.Type, ConstructList()))
	}

	// An access list is a property any construct may carry, so it is validated
	// once here rather than in each branch.
	if in.ACL != nil {
		causes = append(causes, aclCauses(in.ACL)...)
	}

	// The site's own inventory is the last thing an intent can fail on before
	// objects exist on the cluster.
	causes = append(causes, SiteInventoryFromEnv().ValidateEndpoints(in.Endpoints)...)

	if len(causes) > 0 {
		return &ValidationError{Causes: causes}
	}
	return nil
}

// l3vniRenderableCauses rejects an L3VNI the fabric cannot render. SONiC needs
// a VLAN for every VNI and the renderer derives one as 4000 + (vni - 10000)
// into the reserved 4001-4094 band, so only 10000-14094 has a VLAN to derive.
// Outside it the object used to be accepted, submitted, and only then rejected
// by the controller.
func l3vniRenderableCauses(vni int) []string {
	if vni == 0 || (vni >= 10000 && vni <= 14094) {
		return nil
	}
	return []string{fmt.Sprintf(
		"l3vni: %d has no derivable service VLAN; this fabric renders L3VNIs in 10000-14094", vni)}
}

// endpointVLANCauses enforces the one rule every L2 service type shares: a
// bridge domain is ONE broadcast domain, so every endpoint carries the same
// service vlan. The translator renders exactly one bridgeDomain, taking its
// vlan from the first endpoint; a second endpoint on a different vlan produced
// an attachment referencing a vlan no bridgeDomain declared, and the fabric
// rejected it at render time — after submission. VPLS checked this from the
// start; VPWS and IRB did not, which is why neither ever converged.
func endpointVLANCauses(eps []Endpoint, service string) []string {
	var causes []string
	var vlan int
	for i, ep := range eps {
		if ep.VLAN == 0 {
			causes = append(causes, fmt.Sprintf("endpoints[%d].vlan: required for %s", i, service))
			continue
		}
		if vlan == 0 {
			vlan = ep.VLAN
			continue
		}
		if ep.VLAN != vlan {
			causes = append(causes, fmt.Sprintf(
				"endpoints[%d].vlan: %s is one bridge domain, so every endpoint must share one vlan (got %d and %d)",
				i, service, vlan, ep.VLAN))
		}
	}
	return causes
}
