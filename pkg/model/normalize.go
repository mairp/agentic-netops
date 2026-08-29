// SPDX-License-Identifier: Apache-2.0
package model

import (
	"errors"
	"fmt"
)

// ValidationError indicates incomplete, unknown, or conflicting constructs.
type ValidationError struct {
	Field   string
	Reason  string
	Message string
}

func (e *ValidationError) Error() string { return fmt.Sprintf("%s: %s (%s)", e.Field, e.Reason, e.Message) }

// NormalizeInterfaces validates and normalizes interface definitions.
func NormalizeInterfaces(ifs []Interface) ([]Interface, error) {
	seen := map[string]struct{}{}
	out := make([]Interface, 0, len(ifs))
	for _, in := range ifs {
		if in.Name == "" {
			return nil, &ValidationError{Field: "interfaces.name", Reason: "Required", Message: "interface name must be set"}
		}
		if in.MTU != 0 && (in.MTU < 576 || in.MTU > 9216) {
			return nil, &ValidationError{Field: "interfaces.mtu", Reason: "OutOfRange", Message: "MTU must be 576-9216 or omitted"}
		}
		if _, ok := seen[in.Name]; ok {
			return nil, &ValidationError{Field: "interfaces.name", Reason: "Duplicate", Message: "duplicate interface name"}
		}
		seen[in.Name] = struct{}{}
		out = append(out, in)
	}
	return out, nil
}

// NormalizeBGP validates global and neighbor BGP settings.
func NormalizeBGP(global BGPGlobal, nei []BGPNeighbor) (BGPGlobal, []BGPNeighbor, error) {
	if global.ASN == 0 {
		return BGPGlobal{}, nil, &ValidationError{Field: "bgp.asn", Reason: "Required", Message: "ASN must be set"}
	}
	return global, nei, nil
}

// NormalizeNetworkInstances validates VRF/default instances.
func NormalizeNetworkInstances(instances []NetworkInstance) ([]NetworkInstance, error) {
	byName := map[string]struct{}{}
	for _, ni := range instances {
		if ni.Name == "" {
			return nil, &ValidationError{Field: "networkInstance.name", Reason: "Required", Message: "name required"}
		}
		if _, ok := byName[ni.Name]; ok {
			return nil, &ValidationError{Field: "networkInstance.name", Reason: "Duplicate", Message: "duplicate instance name"}
		}
		byName[ni.Name] = struct{}{}
	}
	return instances, nil
}

// NormalizeSRv6 validates SRv6-specific constructs.
func NormalizeSRv6(locator SRv6Locator, mysids []MySID) (SRv6Locator, []MySID, error) {
	if locator.Prefix == "" {
		return SRv6Locator{}, nil, &ValidationError{Field: "srv6.locator", Reason: "Required", Message: "locator prefix required"}
	}
	return locator, mysids, nil
}

// IsTerminal returns true for terminal errors per reconciliation contract.
func IsTerminal(err error) bool {
	var ve *ValidationError
	if errors.As(err, &ve) {
		// Treat schema/unknown/duplicate as terminal until generation or dependency changes
		return true
	}
	return false
}
