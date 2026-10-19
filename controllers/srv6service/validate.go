// SPDX-License-Identifier: Apache-2.0
//
// Site validation, rules C1-C3 (T360-T365): nodes must be leaves of the
// fabric, attachment ports must resolve in the site port map, and preferred /
// alternate spines must be spines. All three refusals are terminal
// InvalidSite conditions listing the valid names
// (contracts/srv6service-crd.md §3).
//
// The fabric facts come from the controller config (env; see SiteFactsFromEnv
// and cmd/srv6-controller/main.go). Defaults match lab/profiles/sonic-vm:
// leaves leaf01/leaf02, spines spine01/spine02, wan1 -> Ethernet12
// (lab/profiles/sonic-vm/port-map.json — the CRD attachment port is the
// LOGICAL name; the renderer resolves it, never guesses it).
package srv6service

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
)

// SiteFacts is the site identity the controller validates against and the
// renderer renders against: node roles, the logical->kernel port map, the
// leaf-side spine link addresses and the bootstrap-owned locators.
type SiteFacts struct {
	// Nodes maps node name to role ("leaf" or "spine").
	Nodes map[string]string
	// PortMap resolves the spec's logical attachment names to kernel ports.
	PortMap fabricplan.PortMapper
	// SpineLinks maps attachment node name to that node's spine legs
	// (spine name -> the leg's IPv6 link address on that node). The legs
	// differ per leaf: leaf01 peers 2001:db8:1::3 toward spine01 while
	// leaf02 peers 2001:db8:1::5 (lab/profiles/sonic-vm/fabric.yaml) — a
	// flat spine->address map is leaf01's view only and cannot serve both.
	SpineLinks map[string]map[string]string
	// Locators maps node name to its bootstrap-owned locator /48.
	Locators map[string]string
	// NodeKind is the lab profile kind the plans target (sonic-vm).
	NodeKind string
}

// Roles of SiteFacts.Nodes.
const (
	RoleLeaf  = "leaf"
	RoleSpine = "spine"
)

// Leaves returns the fabric's leaf names, sorted — the valid names an
// InvalidSite refusal lists for C1.
func (f SiteFacts) Leaves() []string { return f.namesOfRole(RoleLeaf) }

// Spines returns the fabric's spine names, sorted — the valid names an
// InvalidSite refusal lists for C3.
func (f SiteFacts) Spines() []string { return f.namesOfRole(RoleSpine) }

func (f SiteFacts) namesOfRole(role string) []string {
	out := make([]string, 0, len(f.Nodes))
	for n, r := range f.Nodes {
		if r == role {
			out = append(out, n)
		}
	}
	sort.Strings(out)
	return out
}

// RoleOf returns the node's role; ok is false for an unknown node.
func (f SiteFacts) RoleOf(node string) (string, bool) {
	r, ok := f.Nodes[node]
	return r, ok
}

// ValidPorts returns the port map's logical names, sorted (C2's valid list).
func (f SiteFacts) ValidPorts() []string { return f.PortMap.Known() }

// DefaultSiteFacts is the pinned sonic-vm lab (lab/profiles/sonic-vm:
// fabric.yaml for roles and locators, port-map.json for the port map,
// fabric.yaml link addressing for the spine links from the leaf side).
func DefaultSiteFacts() SiteFacts {
	return SiteFacts{
		Nodes: map[string]string{
			"leaf01": RoleLeaf, "leaf02": RoleLeaf,
			"spine01": RoleSpine, "spine02": RoleSpine,
		},
		PortMap: fabricplan.PortMapper{"wan1": "Ethernet12"},
		// Each leaf's OWN view of its spine legs (fabric.yaml peer_v6 on the
		// leaf uplinks; the legs differ per leaf): the renderer pins the /48
		// and the /64 via the pin spine's leg on the node being rendered.
		SpineLinks: map[string]map[string]string{
			"leaf01": {"spine01": "2001:db8:1::3", "spine02": "2001:db8:2::3"},
			"leaf02": {"spine01": "2001:db8:1::5", "spine02": "2001:db8:2::5"},
		},
		Locators: map[string]string{
			"spine01": "fcbb:bbbb:1::/48",
			"spine02": "fcbb:bbbb:2::/48",
			"leaf01":  "fcbb:bbbb:3::/48",
			"leaf02":  "fcbb:bbbb:4::/48",
		},
		NodeKind: "sonic-vm",
	}
}

// SiteFactsFromEnv builds SiteFacts from FABRIC_SITE_FACTS (one JSON object)
// or the individual variables FABRIC_NODES (node->role JSON),
// FABRIC_SPINES (comma-separated names), FABRIC_PORT_MAP (JSON),
// FABRIC_SPINE_LINKS (JSON), FABRIC_LOCATORS (JSON) and FABRIC_NODE_KIND.
// Anything unset falls back to the sonic-vm defaults; an unparsable value
// falls back per-map and the parse error is returned alongside so the caller
// can log it.
func SiteFactsFromEnv() (SiteFacts, error) {
	f := DefaultSiteFacts()
	var firstErr error
	note := func(err error) {
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}

	if raw := os.Getenv("FABRIC_SITE_FACTS"); raw != "" {
		var sf struct {
			Nodes      map[string]string `json:"nodes"`
			PortMap    map[string]string `json:"portMap"`
			SpineLinks map[string]map[string]string `json:"spineLinks"`
			Locators   map[string]string `json:"locators"`
			NodeKind   string            `json:"nodeKind"`
		}
		if err := json.Unmarshal([]byte(raw), &sf); err != nil {
			note(fmt.Errorf("FABRIC_SITE_FACTS: %w", err))
		} else {
			if sf.Nodes != nil {
				f.Nodes = sf.Nodes
			}
			if sf.PortMap != nil {
				f.PortMap = fabricplan.PortMapper(sf.PortMap)
			}
			if sf.SpineLinks != nil {
				f.SpineLinks = sf.SpineLinks
			}
			if sf.Locators != nil {
				f.Locators = sf.Locators
			}
			if sf.NodeKind != "" {
				f.NodeKind = sf.NodeKind
			}
			return f, firstErr
		}
	}

	if raw := os.Getenv("FABRIC_NODES"); raw != "" {
		nodes := map[string]string{}
		if err := json.Unmarshal([]byte(raw), &nodes); err != nil {
			note(fmt.Errorf("FABRIC_NODES: %w", err))
		} else {
			f.Nodes = nodes
		}
	}
	// FABRIC_SPINES names the spines: they are added to (or, with
	// FABRIC_NODES absent, form) the node role map as spines.
	if raw := os.Getenv("FABRIC_SPINES"); raw != "" {
		if f.Nodes == nil {
			f.Nodes = map[string]string{}
		}
		for _, s := range strings.Split(raw, ",") {
			if s = strings.TrimSpace(s); s != "" {
				f.Nodes[s] = RoleSpine
			}
		}
		// Every named node that is not a spine is a leaf.
		for n := range f.Nodes {
			if f.Nodes[n] == "" {
				f.Nodes[n] = RoleLeaf
			}
		}
	}
	if raw := os.Getenv("FABRIC_PORT_MAP"); raw != "" {
		m := fabricplan.PortMapper{}
		if err := json.Unmarshal([]byte(raw), &m); err != nil {
			note(fmt.Errorf("FABRIC_PORT_MAP: %w", err))
		} else {
			f.PortMap = m
		}
	}
	if raw := os.Getenv("FABRIC_SPINE_LINKS"); raw != "" {
		// node -> spine -> that node's leg address (the legs differ per leaf).
		m := map[string]map[string]string{}
		if err := json.Unmarshal([]byte(raw), &m); err != nil {
			note(fmt.Errorf("FABRIC_SPINE_LINKS: %w", err))
		} else {
			f.SpineLinks = m
		}
	}
	if raw := os.Getenv("FABRIC_LOCATORS"); raw != "" {
		m := map[string]string{}
		if err := json.Unmarshal([]byte(raw), &m); err != nil {
			note(fmt.Errorf("FABRIC_LOCATORS: %w", err))
		} else {
			f.Locators = m
		}
	}
	if raw := os.Getenv("FABRIC_NODE_KIND"); raw != "" {
		f.NodeKind = raw
	}
	return f, firstErr
}

// validateSite enforces C1-C3 and returns ONE terminal refusal for the first
// rule that fails (T396: one terminal condition per refusal).
func validateSite(svc *v1alpha1.SRv6Service, facts SiteFacts) *Refusal {
	// C1: every attachment node is a leaf of the fabric.
	for _, att := range svc.Spec.Attachments {
		role, ok := facts.RoleOf(att.Node)
		if !ok {
			return &Refusal{
				Reason:  reasons.ReasonInvalidSite,
				Message: fmt.Sprintf("node %q is not a node of the fabric (valid nodes: %s)", att.Node, joinNames(sortedKeys(facts.Nodes))),
				Kind:    refusalSite,
			}
		}
		if role != RoleLeaf {
			return &Refusal{
				Reason:  reasons.ReasonInvalidSite,
				Message: fmt.Sprintf("node %q is a %s, not a leaf (valid leaves: %s)", att.Node, role, joinNames(facts.Leaves())),
				Kind:    refusalSite,
			}
		}
	}
	// C2: every attachment port resolves in the site port map.
	for _, att := range svc.Spec.Attachments {
		if _, err := facts.PortMap.Port(att.Port); err != nil {
			return &Refusal{
				Reason:  reasons.ReasonInvalidSite,
				Message: fmt.Sprintf("port %q does not resolve in the site port map (valid ports: %s)", att.Port, joinNames(facts.ValidPorts())),
				Kind:    refusalSite,
			}
		}
	}
	// C3: preferred and alternate spines are spines of the fabric.
	spines := facts.Spines()
	for _, s := range []string{svc.Spec.Path.PreferredSpine, svc.Spec.Path.AlternateSpine} {
		if s == "" {
			continue
		}
		if role, ok := facts.RoleOf(s); !ok || role != RoleSpine {
			return &Refusal{
				Reason:  reasons.ReasonInvalidSite,
				Message: fmt.Sprintf("spine %q is not a spine of the fabric (valid spines: %s)", s, joinNames(spines)),
				Kind:    refusalSite,
			}
		}
	}
	return nil
}

// sortedKeys returns the sorted keys of a string map.
func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func joinNames(names []string) string {
	if len(names) == 0 {
		return "none"
	}
	return strings.Join(names, ", ")
}
