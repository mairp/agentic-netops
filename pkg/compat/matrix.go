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
		SonicImage:        ann["ainetops.dev/sonic-image"],
		OpenConfigCommit:  ann["ainetops.dev/openconfig-commit"],
		SonicNativeCommit: ann["ainetops.dev/sonic-native-commit"],
		MappingVersion:    ann["ainetops.dev/mapping-version"],
		UpstreamAPIVersions: map[string]string{
			"kubenet": ann["ainetops.dev/kubenet-commit"],
			"kuid":    ann["ainetops.dev/kuid-commit"],
			"sdc":     ann["ainetops.dev/sdc-release"],
		},
	}
	return set
}

// ValidatePins performs stricter checks on the Set pins for shape and presence.
func ValidatePins(set Set) error {
	if set.SonicImage == "" {
		return &ValidationError{Reason: "SchemaMismatch", Message: "missing sonic image pin"}
	}
	if !sha1re.MatchString(set.OpenConfigCommit) || !sha1re.MatchString(set.SonicNativeCommit) {
		return &ValidationError{Reason: "SchemaMismatch", Message: "schema pins must be commit SHAs"}
	}
	if !semverRe.MatchString(set.UpstreamAPIVersions["sdc"]) {
		return &ValidationError{Reason: "SchemaMismatch", Message: "sdc release must be semver"}
	}
	return nil
}

// ValidateContracts ensures that pinned telemetry/topology label contracts are present.
func ValidateContracts(labels map[string]string) error {
	if labels["ainetops.dev/topology-label-contract"] == "" {
		return &ValidationError{Reason: "SchemaMismatch", Message: "missing topology label contract pin"}
	}
	if labels["ainetops.dev/telemetry-label-contract"] == "" {
		return &ValidationError{Reason: "SchemaMismatch", Message: "missing telemetry label contract pin"}
	}
	return nil
}

// FullValidate runs pin checks plus optional capability gates.
func FullValidate(set Set, labels map[string]string, discovered map[string]bool) error {
	if err := ValidatePins(set); err != nil {
		return err
	}
	if err := ValidateContracts(labels); err != nil {
		return err
	}
	if err := Validate(set, discovered); err != nil {
		return err
	}
	return nil
}

func ReasonFor(err error) string {
	if v, ok := err.(*ValidationError); ok {
		return v.Reason
	}
	return "ValidationFailed"
}
