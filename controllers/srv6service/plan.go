// SPDX-License-Identifier: Apache-2.0
//
// Plan stage, T378-T379: render the service with fabricplan.ForSRv6Service
// (contracts/fabricplan-srv6.md §1) from the claimed allocations and the site
// facts, and hash each node's rendered ops into status.configHashes — the
// basis of the zero-write re-apply (T390-T391, also here): when the stored
// hashes match the freshly computed ones and every check passes on verify,
// NO apply call is made.
package srv6service

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
)

// BuildPlan renders the per-node work order. Pure over (svc, alloc, facts).
func BuildPlan(svc *v1alpha1.SRv6Service, alloc *Allocation, facts SiteFacts) (*fabricplan.Plan, error) {
	return fabricplan.ForSRv6Service(svc, fabricplan.Allocations{
		ServiceID:      alloc.Allocations.ServiceID,
		VRF:            alloc.Allocations.VRF,
		ServiceSIDs:    alloc.ServiceSIDs,
		ClientPrefixes: alloc.Allocations.ClientPrefixes,
	}, fabricplan.SRv6Options{
		Ports:      facts.PortMap,
		NodeKind:   facts.NodeKind,
		SpineLinks: facts.SpineLinks,
		Locators:   facts.Locators,
	})
}

// PlanOrder returns the plan's node names in deterministic (sorted) order —
// the apply/verify/rollback order (T380).
func PlanOrder(plan *fabricplan.Plan) []string {
	out := make([]string, 0, len(plan.Nodes))
	for name := range plan.Nodes {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// PlanHashes hashes each node's rendered ops (sha256 of the canonical JSON of
// the ops list). The ops are the device work; checks and rollback are derived
// and need no separate hash.
func PlanHashes(plan *fabricplan.Plan) map[string]string {
	out := map[string]string{}
	for name, np := range plan.Nodes {
		out[name] = nodeHash(np.Ops)
	}
	return out
}

func nodeHash(ops []fabricplan.Op) string {
	b, err := json.Marshal(ops)
	if err != nil {
		// The ops are maps/strings/slices: marshalling cannot fail. If it
		// ever does, the hash names the failure rather than silently matching.
		return "unencodable"
	}
	return fmt.Sprintf("%x", sha256.Sum256(b))
}

// hashesEqual reports whether the stored status hashes match the freshly
// computed ones for every node of the plan.
func hashesEqual(stored, fresh map[string]string) bool {
	if len(stored) == 0 {
		return false
	}
	for node, h := range fresh {
		if stored[node] != h {
			return false
		}
	}
	return true
}
