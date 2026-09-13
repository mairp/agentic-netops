// SPDX-License-Identifier: Apache-2.0
package compat

import (
	"regexp"
)

var sha1re = regexp.MustCompile(`^[0-9a-f]{7,40}$`)
var semverRe = regexp.MustCompile(`^v\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$`)

// FromAnnotations extracts a compatibility Set from labels/annotations maps.
func FromAnnotations(ann map[string]string) Set {
	set := Set{
		SRLinuxImage:   ann["agentic-netops.dev/srlinux-image"],
		SRLinuxYANG:    ann["agentic-netops.dev/srlinux-yang"],
		MappingVersion: ann["agentic-netops.dev/mapping-version"],
		UpstreamAPIVersions: map[string]string{
			"kubenet": ann["agentic-netops.dev/kubenet-commit"],
			"kuid":    ann["agentic-netops.dev/kuid-commit"],
			"sdc":     ann["agentic-netops.dev/sdc-release"],
		},
	}
	return set
}

// ValidatePins performs stricter checks on the Set pins for shape and presence.
func ValidatePins(set Set) error {
	if set.SRLinuxImage == "" {
		return &ValidationError{Reason: "SchemaMismatch", Message: "missing SR Linux image pin"}
	}
	// The YANG pin is a release of nokia/srlinux-yang-models (research D1), so
	// it is a semver tag — not the commit SHA the SONiC target's two schema
	// pins were. A site that pins it any other way has not pinned it.
	if !semverRe.MatchString(set.SRLinuxYANG) {
		return &ValidationError{Reason: "SchemaMismatch", Message: "srlinux yang pin must be a semver release (for example v26.7.2)"}
	}
	if !semverRe.MatchString(set.UpstreamAPIVersions["sdc"]) {
		return &ValidationError{Reason: "SchemaMismatch", Message: "sdc release must be semver"}
	}
	if c := set.UpstreamAPIVersions["kubenet"]; c != "" && !sha1re.MatchString(c) {
		return &ValidationError{Reason: "SchemaMismatch", Message: "kubenet pin must be a commit SHA"}
	}
	if c := set.UpstreamAPIVersions["kuid"]; c != "" && !sha1re.MatchString(c) {
		return &ValidationError{Reason: "SchemaMismatch", Message: "kuid pin must be a commit SHA"}
	}
	return nil
}

// ValidateContracts ensures that pinned telemetry/topology label contracts are present.
func ValidateContracts(labels map[string]string) error {
	if labels["agentic-netops.dev/topology-label-contract"] == "" {
		return &ValidationError{Reason: "SchemaMismatch", Message: "missing topology label contract pin"}
	}
	if labels["agentic-netops.dev/telemetry-label-contract"] == "" {
		return &ValidationError{Reason: "SchemaMismatch", Message: "missing telemetry label contract pin"}
	}
	return nil
}

// FullValidate runs pin checks, contract checks and the capability gates the
// caller asks for. Callers that need no platform capability beyond what every
// SR Linux node has (a `Network`: vlan, mac-vrf, ip-vrf, acl) pass none, and
// reconcile on a site whose `cap-sai-srv6` is "false".
func FullValidate(set Set, labels map[string]string, discovered map[string]bool, required ...string) error {
	if err := ValidatePins(set); err != nil {
		return err
	}
	if err := ValidateContracts(labels); err != nil {
		return err
	}
	return Validate(set, discovered, required...)
}

func ReasonFor(err error) string {
	if v, ok := err.(*ValidationError); ok {
		return v.Reason
	}
	return "ValidationFailed"
}
