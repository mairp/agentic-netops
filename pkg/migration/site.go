// SPDX-License-Identifier: Apache-2.0
package migration

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// SiteInventory is what the fabric will actually accept: the logical node
// names the fabric-executor can reach (FABRIC_NODE_MAP) and the logical
// attachment names the renderer can resolve to kernel ports (FABRIC_PORT_MAP).
//
// It exists because an endpoint naming a node or a port the site does not have
// used to travel all the way to the cluster: the deployer reported a
// successful submission, the object was created, and only then did the
// controller render it and fail with SchemaMismatch — leaving the operator a
// stranded Network to clean up and a "correct the intent and submit a fresh
// request" message that never said what the valid names were. Checking here,
// in the same all-or-nothing gate as every other cause, means nothing is
// submitted and the rejection names the site's real choices.
type SiteInventory struct {
	Nodes       []string
	Attachments []string
}

// SiteInventoryFromEnv reads the site's two maps from the environment. It
// returns nil when neither is configured: the CLI and the unit tests translate
// without a site, and inventing an inventory there would reject valid input.
func SiteInventoryFromEnv() *SiteInventory {
	nodes := keysOfJSONMap(os.Getenv("FABRIC_NODE_MAP"))
	ports := keysOfJSONMap(os.Getenv("FABRIC_PORT_MAP"))
	if len(nodes) == 0 && len(ports) == 0 {
		return nil
	}
	return &SiteInventory{Nodes: nodes, Attachments: ports}
}

func keysOfJSONMap(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	m := map[string]string{}
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		return nil
	}
	out := make([]string, 0, len(m))
	for k, v := range m {
		if v != "" {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// normalizeSiteName folds the spellings of one logical name together: case and
// separators are notation, not intent ("Ethernet1" and "ethernet1" name the
// same port; "Leaf01" and "leaf01" the same node). It never invents a name.
func normalizeSiteName(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func knows(names []string, want string) bool {
	norm := normalizeSiteName(want)
	for _, n := range names {
		if normalizeSiteName(n) == norm {
			return true
		}
	}
	return false
}

// ValidateEndpoints names every endpoint the site cannot honour. An empty
// return means every endpoint resolves; a nil inventory validates nothing.
func (s *SiteInventory) ValidateEndpoints(eps []Endpoint) []string {
	if s == nil {
		return nil
	}
	var causes []string
	for i, ep := range eps {
		if len(s.Nodes) > 0 && !knows(s.Nodes, ep.Node) {
			causes = append(causes, fmt.Sprintf(
				"endpoints[%d].node: %q is not a node at this site (site has: %s)",
				i, ep.Node, strings.Join(s.Nodes, ", ")))
		}
		if len(s.Attachments) > 0 && !knows(s.Attachments, ep.Attachment) {
			causes = append(causes, fmt.Sprintf(
				"endpoints[%d].attachment: %q is not an attachment point at this site (site has: %s)",
				i, ep.Attachment, strings.Join(s.Attachments, ", ")))
		}
	}
	return causes
}
