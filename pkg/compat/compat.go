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

// Validate performs offline validation of the compatibility set against the pinned contract
// in versions.lock.yaml and optionally a discovered target capability set.
func Validate(set Set, discovered map[string]bool) error {
	// Minimal scaffold: ensure non-empty pins and required SRv6 capability flag when mapping requires it.
	if set.SonicImage == "" || set.OpenConfigCommit == "" || set.SonicNativeCommit == "" || set.MappingVersion == "" {
		return &ValidationError{Reason: "SchemaMismatch", Message: "incomplete compatibility set"}
	}
	if discovered != nil {
		// SAI SRv6 capability gate (placeholder key)
		if requiresSRv6(set.MappingVersion) && !discovered["sai.srv6"] {
			return &ValidationError{Reason: "CapabilityMissing", Message: "SRv6 not supported by target"}
		}
	}
	return nil
}

func requiresSRv6(mappingVersion string) bool { return true }
