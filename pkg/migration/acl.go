// SPDX-License-Identifier: Apache-2.0
package migration

import (
	"fmt"
	"strings"
)

// AccessListRule is the render-side alias for an ACL rule carried in the NetworkSpec.
// It is an exact alias of ACLRule and exists for evidence and contract clarity.
type AccessListRule = ACLRule

// AccessList is the render-side alias for ACL carried in the NetworkSpec.
// It is an exact alias of ACL used when serializing the Network spec.
type AccessList = ACL

// NetworkVLAN is the render-side VLAN entry carried in the NetworkSpec.
// Kept here alongside ACL helpers for the translator.
// (The spec field is spec.vlans[].)
// Note: This type is referenced from pkg/migration/translate.go.
// Do not move without updating imports across the package.
type NetworkVLAN struct {
	Name string `json:"name"`
	VLAN int    `json:"vlan"`
}

// accessListFor materializes a rendered ACL name defaulted from service id
// and returns a distinct value to carry within the NetworkSpec.
func accessListFor(a *ACL, serviceID string) AccessList {
	if a == nil {
		return AccessList{}
	}
	out := *a
	if out.Name == "" {
		out.Name = fmt.Sprintf("acl-%s", serviceID)
	}
	return out
}

// attachmentsForPorts renders only node and attachment, leaving vlan/vrf empty.
// An ACL-only service binds to ports and carries neither vlan nor vrf.
func attachmentsForPorts(eps []Endpoint) []Attachment {
	var out []Attachment
	for _, ep := range eps {
		out = append(out, Attachment{Node: ep.Node, Attachment: ep.Attachment})
	}
	return out
}

// DeviceACLTableName derives an on-device ACL table name for <serviceID>/<stage>
// that matches the sonic-acl.yang identifier constraints:
//   - ^[a-zA-Z0-9]{1}([-a-zA-Z0-9_]{1,63})$
//
// The derivation: prefix an alphanumeric, sanitize to the YANG alphabet, cap
// the remainder to 63 chars after the first, and include the stage to make the
// tuple deterministic per ingress/egress.
func DeviceACLTableName(serviceID, stage string) (string, error) {
	if serviceID == "" {
		return "", fmt.Errorf("empty serviceID")
	}
	// Base pattern: acl-<serviceID>-<stage>
	base := fmt.Sprintf("acl-%s-%s", serviceID, stage)
	// Sanitize: keep only A-Z a-z 0-9 - _
	var b strings.Builder
	for _, r := range base {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		}
	}
	s := b.String()
	if s == "" {
		// Should not happen given serviceID non-empty, but guard anyway.
		s = "acl"
	}
	// Ensure first char is alphanumeric; prefix 'A' when not.
	first := s[0]
	if !((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') || (first >= '0' && first <= '9')) {
		s = "A" + s
	}
	// Cap total length: first char + up to 63 more = 64 max.
	if len(s) > 64 {
		s = s[:64]
	}
	return s, nil
}
