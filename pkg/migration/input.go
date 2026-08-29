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
	TranslatorName    = "ainetops-migration-translator"
	TranslatorVersion = "v0.1.0"
	MappingVersion    = "v0.1.0"
)

// ServiceType enumerates supported normalized service kinds.
type ServiceType string

const (
	ServiceVPLS  ServiceType = "VPLS"         // multipoint L2VPN
	ServiceL3VPN ServiceType = "L3VPN"        // routed VPN
	ServiceVPWS ServiceType = "VPWS"          // E-Line
	ServiceIRB  ServiceType = "L2L3-IRB"      // integrated L2/L3 (symmetric-IRB)
)

// AddressFamilies captures AFI-specific properties for L3VPN.
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
	Node       string `json:"node"`                 // required leaf name
	Attachment string `json:"attachment"`          // human-readable peer/endpoint id
	VLAN       int    `json:"vlan,omitempty"`      // for L2 services
	VRF        string `json:"vrf,omitempty"`       // for L3/IRB attachments
}

// IRBGateway parameters for symmetric-IRB.
type IRBGateway struct {
	VRF        string `json:"vrf"`
	GatewayV4  string `json:"gatewayIPv4"`
	GatewayV6  string `json:"gatewayIPv6"`
}

// Policies are explicit allow-listed options.
type Policies struct {
	// VPWSLimitedEquivalence must be true to allow VPWS-to-L2VNI mapping.
	VPWSLimitedEquivalence bool `json:"vpwsLimitedEquivalence,omitempty"`
}

// UnsupportedClaims declare source-only features that must be rejected (FR-011).
// Presence of any field here causes a terminal validation failure with details.
type UnsupportedClaims struct {
	TEPolicy         any `json:"tePolicy,omitempty"`
	PseudowireOAM    any `json:"pseudowireOAM,omitempty"`
	ControlWord      any `json:"controlWord,omitempty"`
	MulticastVPN     any `json:"multicastVPN,omitempty"`
	ComplexQoS       any `json:"complexQoS,omitempty"`
	ServiceChain     any `json:"serviceChain,omitempty"`
	RawCLI           any `json:"rawCLI,omitempty"`
}

// ServiceInput is the strict normalized migration input schema.
// Raw CLI is explicitly forbidden; unknown fields cause validation failure.
// Deterministic translation requires RD/RT and VNI inputs to be explicit.
type ServiceInput struct {
	// Identity
	ServiceID string      `json:"serviceId"`
	Type      ServiceType `json:"type"`      // VPLS | L3VPN | VPWS | L2L3-IRB
	Tenant    string      `json:"tenant"`

	// VPN properties
	RDRT   *RdRt            `json:"rdRt,omitempty"`
	L2VNI  int              `json:"l2vni,omitempty"` // for VPLS/VPWS/IRB bridge domains
	L3VNI  int              `json:"l3vni,omitempty"` // for L3VPN/IRB VRFs
	AF     *AddressFamilies `json:"addressFamilies,omitempty"`

	// IRB per-BD gateways (when Type == L2L3-IRB)
	IRBGateway *IRBGateway `json:"irbGateway,omitempty"`

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
	if u.TEPolicy != nil { causes = append(causes, "unsupported: tePolicy") }
	if u.PseudowireOAM != nil { causes = append(causes, "unsupported: pseudowireOAM") }
	if u.ControlWord != nil { causes = append(causes, "unsupported: controlWord") }
	if u.MulticastVPN != nil { causes = append(causes, "unsupported: multicastVPN") }
	if u.ComplexQoS != nil { causes = append(causes, "unsupported: complexQoS") }
	if u.ServiceChain != nil { causes = append(causes, "unsupported: serviceChain") }
	if u.RawCLI != nil { causes = append(causes, "unsupported: rawCLI") }

	// Endpoints basics
	if len(in.Endpoints) == 0 { causes = append(causes, "endpoints: at least one endpoint is required") }

	switch in.Type {
	case ServiceVPLS:
		if in.L2VNI == 0 { causes = append(causes, "l2vni: required for VPLS") }
		if in.RDRT == nil { causes = append(causes, "rdRt: required for VPLS") }
		if len(in.Endpoints) < 2 { causes = append(causes, "endpoints: VPLS requires >=2 endpoints") }
		// All endpoints must specify same VLAN
		var vlan int
		for i, ep := range in.Endpoints {
			if ep.VLAN == 0 { causes = append(causes, fmt.Sprintf("endpoints[%d].vlan: required for VPLS", i)) }
			if i == 0 { vlan = ep.VLAN } else if ep.VLAN != vlan { causes = append(causes, "endpoints.vlan: must be equal across all endpoints for VPLS") }
		}
	case ServiceL3VPN:
		if in.L3VNI == 0 { causes = append(causes, "l3vni: required for L3VPN") }
		if in.RDRT == nil { causes = append(causes, "rdRt: required for L3VPN") }
		if in.AF == nil || (len(in.AF.IPv4Prefixes) == 0 && len(in.AF.IPv6Prefixes) == 0) {
			causes = append(causes, "addressFamilies: at least one prefix is required for L3VPN")
		}
		if len(in.Endpoints) < 1 { causes = append(causes, "endpoints: L3VPN requires >=1 endpoint") }

		for i, ep := range in.Endpoints {
			if ep.VRF == "" { causes = append(causes, fmt.Sprintf("endpoints[%d].vrf: required for L3VPN", i)) }
		}
	case ServiceVPWS:
		if in.L2VNI == 0 { causes = append(causes, "l2vni: required for VPWS") }
		if in.RDRT == nil { causes = append(causes, "rdRt: required for VPWS") }
		if len(in.Endpoints) != 2 { causes = append(causes, "endpoints: VPWS requires exactly 2 endpoints") }
		for i, ep := range in.Endpoints {
			if ep.VLAN == 0 { causes = append(causes, fmt.Sprintf("endpoints[%d].vlan: required for VPWS", i)) }
		}
		if !in.Policies.VPWSLimitedEquivalence {
			causes = append(causes, "policy: vpwsLimitedEquivalence must be true to allow limited equivalence mapping")
		}
	case ServiceIRB:
		if in.L2VNI == 0 { causes = append(causes, "l2vni: required for IRB bridge domain") }
		if in.L3VNI == 0 { causes = append(causes, "l3vni: required for IRB VRF") }
		if in.RDRT == nil { causes = append(causes, "rdRt: required for IRB VRF") }
		if in.IRBGateway == nil { causes = append(causes, "irbGateway: required for IRB") }
		if in.IRBGateway != nil {
			if in.IRBGateway.VRF == "" { causes = append(causes, "irbGateway.vrf: required") }
			if in.IRBGateway.GatewayV4 == "" { causes = append(causes, "irbGateway.gatewayIPv4: required") }
			if in.IRBGateway.GatewayV6 == "" { causes = append(causes, "irbGateway.gatewayIPv6: required") }
		}
		if len(in.Endpoints) < 1 { causes = append(causes, "endpoints: IRB requires at least one endpoint") }
		for i, ep := range in.Endpoints {
			if ep.VLAN == 0 { causes = append(causes, fmt.Sprintf("endpoints[%d].vlan: required for IRB", i)) }
		}
	default:
		causes = append(causes, fmt.Sprintf("type: unsupported '%s'", in.Type))
	}

	if len(causes) > 0 {
		return &ValidationError{Causes: causes}
	}
	return nil
}
