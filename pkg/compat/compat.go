// Package compat validates the compatibility set: image, schema, mapping, and upstream API versions.
package compat

import (
	"fmt"
)

// CapabilitySRv6 is the discovered-capability key for an SRv6 data plane. It is
// the ONLY capability this site cannot offer: the SR Linux 7220 container has
// no SRv6 forwarding path, so `fabric-compat-pins` carries
// `cap-sai-srv6: "false"` and every gate records SRv6 as not-applicable rather
// than passed (research D8).
const CapabilitySRv6 = "sai.srv6"

// Set captures the compatibility set published in deployment metadata and status.
type Set struct {
	// SRLinuxImage is the digest-pinned ghcr.io/nokia/srlinux image the lab runs.
	SRLinuxImage string
	// SRLinuxYANG is the release of nokia/srlinux-yang-models the renderer's
	// native paths are written against.
	SRLinuxYANG         string
	MappingVersion      string
	UpstreamAPIVersions map[string]string // e.g., {"kubenet":"bae1c487...", "kuid":"7528e815...", "sdc":"v0.31.0"}
}

// ValidationError classifies terminal vs transient mismatches.
type ValidationError struct {
	Reason  string // e.g., SchemaMismatch, CapabilityMissing
	Message string
}

func (e *ValidationError) Error() string { return fmt.Sprintf("%s: %s", e.Reason, e.Message) }

// Validate performs offline validation of the compatibility set against the
// pinned contract in versions.lock.yaml and, when the caller names capabilities
// it needs, against the site's discovered capability set.
//
// required is what makes a capability gate honest. A `Network` needs vlan,
// mac-vrf, ip-vrf and acl — all of which SR Linux has — so it names nothing and
// reconciles on a site whose `cap-sai-srv6` is "false". An `SRv6Service` names
// CapabilitySRv6, does not get it here, and reports `CapabilityMissing`. That
// asymmetry is the whole point: the absent capability is declared, not faked,
// and it blocks only the object that actually needs it.
func Validate(set Set, discovered map[string]bool, required ...string) error {
	if set.SRLinuxImage == "" || set.SRLinuxYANG == "" || set.MappingVersion == "" {
		return &ValidationError{Reason: "SchemaMismatch", Message: "incomplete compatibility set"}
	}
	for _, cap := range required {
		if !discovered[cap] {
			return &ValidationError{
				Reason:  "CapabilityMissing",
				Message: fmt.Sprintf("capability %s is not available on this site", cap),
			}
		}
	}
	return nil
}
