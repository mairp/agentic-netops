// Package compat validates the compatibility set: image, schema, mapping, and upstream API versions.
package compat

import (
	"fmt"
)

// Set captures the five-part compatibility set published in deployment metadata and status.
type Set struct {
	SonicImage          string
	OpenConfigCommit    string
	SonicNativeCommit   string
	MappingVersion      string
	UpstreamAPIVersions map[string]string // e.g., {"kubenet":"bae1c487...", "kuid":"7528e815...", "sdc":"v0.31.0"}
}

// ValidationError classifies terminal vs transient mismatches.
type ValidationError struct {
	Reason  string // e.g., SchemaMismatch, CapabilityMissing
	Message string
}

func (e *ValidationError) Error() string { return fmt.Sprintf("%s: %s", e.Reason, e.Message) }

// ObjectKind names the API object kind a compatibility decision is made for
// (T017, FR-007): capability requirements are per object kind, not global.
type ObjectKind string

const (
	KindNetwork       ObjectKind = "Network"
	KindNetworkDevice ObjectKind = "NetworkDevice"
	KindSRv6Service   ObjectKind = "SRv6Service"
)

// Validate performs offline validation of the compatibility set against the pinned contract
// in versions.lock.yaml and optionally a discovered target capability set.
func Validate(set Set, kind ObjectKind, discovered map[string]bool) error {
	// Minimal scaffold: ensure non-empty pins and per-kind capability gates.
	if set.SonicImage == "" || set.OpenConfigCommit == "" || set.SonicNativeCommit == "" || set.MappingVersion == "" {
		return &ValidationError{Reason: "SchemaMismatch", Message: "incomplete compatibility set"}
	}
	if discovered != nil {
		// SAI SRv6 capability gate (placeholder key), scoped to the object
		// kind that actually delivers an SRv6 service (T017).
		if requiresSRv6(kind) && !discovered["sai.srv6"] {
			return &ValidationError{Reason: "CapabilityMissing", Message: "SRv6 not supported by target"}
		}
	}
	return nil
}

// requiresSRv6 (T017, FR-007): the SRv6 capability is required for SRv6Service
// objects only. Until this feature proves SRv6 on a site, every lab honestly
// reports cap-sai-srv6=false, and the VXLAN constructs (Network, NetworkDevice)
// must keep provisioning there.
func requiresSRv6(kind ObjectKind) bool { return kind == KindSRv6Service }
