// SPDX-License-Identifier: Apache-2.0
package render

import (
	"sort"

	"github.com/mairp/agentic-netops/pkg/model"
)

// RenderACL emits SONiC-native ACL_TABLE and ACL_RULE paths for access-lists.
//
// Paths:
//   - /sonic-acl:sonic-acl/ACL_TABLE
//   - /sonic-acl:sonic-acl/ACL_RULE
//
// This function intentionally models only the path/shape needed by the
// path-register guard; it is not consumed by the fabric planner, which writes
// ACL rows through raw-redis operations (contracts/acl-render-contract.md §1).
func RenderACL(acls []model.ACL) map[string]any {
	res := map[string]any{}
	if len(acls) == 0 {
		return res
	}
	// deterministic order by ACL name
	names := make([]string, 0, len(acls))
	byName := map[string]model.ACL{}
	for _, a := range acls {
		n := a.Name
		if n == "" {
			n = "acl"
		}
		byName[n] = a
		names = append(names, n)
	}
	sort.Strings(names)

	// Tables
	tables := []map[string]any{}
	rules := []map[string]any{}
	for _, name := range names {
		a := byName[name]
		// Minimal table shape: name, stage, type, ports, policy_desc
		tables = append(tables, map[string]any{
			"name":        name,
			"stage":       a.Stage,
			"type":        a.Type,
			"ports":       a.Ports,
			"policy_desc": a.PolicyDesc,
		})
		for _, r := range a.Rules {
			rules = append(rules, map[string]any{
				"aclname":  name,
				"rulename": r.Name,
				"priority": r.Priority,
				"action":   r.Action,
				"protocol": r.Protocol,
				"src":      r.SourcePrefix,
				"dst":      r.DestinationPrefix,
				"l4src":    r.SourcePort,
				"l4dst":    r.DestinationPort,
				"desc":     r.Description,
			})
		}
		if a.DefaultAction != "" {
			rules = append(rules, map[string]any{
				"aclname":  name,
				"rulename": "default",
				"priority": 1,
				"action":   a.DefaultAction,
			})
		}
	}
	res["/sonic-acl:sonic-acl/ACL_TABLE"] = tables
	res["/sonic-acl:sonic-acl/ACL_RULE"] = rules
	return res
}
