// SPDX-License-Identifier: Apache-2.0
//
// Verify stage, T382-T385: run every per-node check of the plan through the
// executor and fill status.nodes[] from the observed results. Checks read
// device state, never the plan's own intent (contracts/fabricplan-srv6.md §1).
//
//   - a failing check gives a non-terminal CheckFailed naming the node and
//     the check;
//   - a missing or changed bootstrap locator gives a terminal LocatorMissing
//     naming the node — and is NEVER repaired: the locator is bootstrap-owned
//     (FR-006), so the check below is a dedicated read-only probe, and no op
//     in any plan this controller applies can create, change or remove a
//     locator.
package srv6service

import (
	"context"
	"fmt"
	"strings"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
)

// locatorCheck renders the read-only bootstrap-locator probe for a node: the
// CONFIG_DB row SRV6_MY_LOCATORS|loc-<node> must still carry the node's
// locator (data-model.md §8.4 read-back). The row's `prefix` field holds the
// BARE /48 address — the bootstrap writes `${loc%/*}` (`fcbb:bbbb:3::`,
// never `fcbb:bbbb:3::/48`), so the probe reads that field and expects the
// bare address; a key-name scan cannot match a prefix length. It is NOT part
// of the plan's checks — it runs first, and a failure short-circuits the
// node's verify.
func locatorCheck(node, locator string) fabricplan.Check {
	return fabricplan.Check{
		Type:       "redis-hget",
		RedisKey:   "SRV6_MY_LOCATORS|loc-" + node,
		RedisField: "prefix",
		Expect:     strings.TrimSuffix(locator, "/48"),
	}
}

// verifyResult is one node's observed verify outcome.
type verifyResult struct {
	Node        string
	Verified    bool
	FailedCheck string // "checks[i].<type>" as the executor names checks
	Err         error
	Refusal     *Refusal
}

// verifyNode verifies one node: the locator probe first, then the plan's
// checks.
func verifyNode(ctx context.Context, ex Executor, node string, checks []fabricplan.Check, locator string) verifyResult {
	// Locator probe: a missing or changed bootstrap locator is terminal and
	// never repaired.
	locRes, err := ex.Verify(ctx, node, []fabricplan.Check{locatorCheck(node, locator)})
	if err != nil {
		return verifyResult{Node: node, Err: err}
	}
	if !checkOK(locRes, 0) {
		return verifyResult{
			Node: node,
			Refusal: &Refusal{
				Reason: reasons.ReasonLocatorMissing,
				Message: fmt.Sprintf("bootstrap locator %s is absent or changed on node %s; locators are bootstrap-owned and are never written by this controller",
					locator, node),
				Kind: refusalLocator,
			},
		}
	}

	if len(checks) == 0 {
		return verifyResult{Node: node, Verified: true}
	}
	res, err := ex.Verify(ctx, node, checks)
	if err != nil {
		return verifyResult{Node: node, Err: err}
	}
	for i := range checks {
		if !checkOK(res, i) {
			name := checkDisplayName(checkName(res, i), checks[i])
			return verifyResult{
				Node:        node,
				FailedCheck: name,
				// The check that failed and the node, in the message the §6
				// table requires.
				Refusal: &Refusal{
					Reason: reasons.ReasonCheckFailed,
					Message: fmt.Sprintf("check %s failed on node %s: %s",
						name, node, checkDetail(res, i)),
					Kind: refusalCheck,
				},
			}
		}
	}
	return verifyResult{Node: node, Verified: true}
}

// verifyPlan verifies every node in plan order and returns the status node
// list plus the first refusal (LocatorMissing or CheckFailed).
func verifyPlan(ctx context.Context, ex Executor, plan *fabricplan.Plan, order []string, locators map[string]string) ([]v1alpha1.NodeStatus, *Refusal) {
	nodes := make([]v1alpha1.NodeStatus, 0, len(order))
	for _, node := range order {
		np := plan.Nodes[node]
		res := verifyNode(ctx, ex, node, np.Checks, locators[node])
		st := v1alpha1.NodeStatus{Node: node, Verified: res.Verified}
		if res.FailedCheck != "" {
			st.FailedCheck = res.FailedCheck
		}
		nodes = append(nodes, st)
		if res.Err != nil {
			return nodes, &Refusal{
				Reason:  reasons.ReasonCheckFailed,
				Message: fmt.Sprintf("verify on node %s failed: %v", node, res.Err),
				Kind:    refusalCheck,
			}
		}
		if res.Refusal != nil {
			return nodes, res.Refusal
		}
	}
	return nodes, nil
}

// checkOK reports whether the i'th result of a verify response passed,
// tolerating a short response.
func checkOK(res *executorclient.VerifyResult, i int) bool {
	if res == nil || i >= len(res.Results) {
		return false
	}
	return res.Results[i].OK
}

func checkName(res *executorclient.VerifyResult, i int) string {
	if res == nil || i >= len(res.Results) || res.Results[i].Check == "" {
		return fmt.Sprintf("checks[%d]", i)
	}
	return res.Results[i].Check
}

// checkDisplayName names a failed check for humans: the executor's own name
// when it carries one, enriched with what the check asserts (describeCheck)
// when the executor only supplies an index; never a bare index into the
// plan's check list (quickstart Q6 names the check).
func checkDisplayName(executorName string, c fabricplan.Check) string {
	if executorName != "" && !strings.HasPrefix(executorName, "checks[") {
		return executorName
	}
	if executorName == "" {
		return describeCheck(c)
	}
	return executorName + " (" + describeCheck(c) + ")"
}

// describeCheck names a check by the state it asserts.
func describeCheck(c fabricplan.Check) string {
	switch {
	case c.Command != "":
		return fmt.Sprintf("command %q", head(c.Command, 48))
	case c.RedisKey != "" && c.RedisField != "":
		return fmt.Sprintf("redis-hget %s|%s", c.RedisKey, c.RedisField)
	case c.RedisKey != "":
		return fmt.Sprintf("%s %s", c.Type, c.RedisKey)
	case c.Iface != "" && c.Addr != "":
		return fmt.Sprintf("ip-addr %s carries %s", c.Iface, c.Addr)
	case c.Iface != "" && c.Master != "":
		return fmt.Sprintf("ip-master %s enslaved to %s", c.Iface, c.Master)
	case c.Iface != "" && c.Vid != 0:
		return fmt.Sprintf("bridge-vid %s vid %d", c.Iface, c.Vid)
	case c.Path != "":
		return fmt.Sprintf("file-contains %s", c.Path)
	case c.ProbeFrom != "":
		return fmt.Sprintf("probe-ping %s to %s", c.ProbeFrom, c.ProbeTo)
	case c.OnClient != "":
		return fmt.Sprintf("client-addressing %s", c.OnClient)
	default:
		return "check " + c.Type
	}
}

// head bounds s to at most n runes plus an ellipsis.
func head(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

func checkDetail(res *executorclient.VerifyResult, i int) string {
	if res == nil || i >= len(res.Results) {
		return "no result"
	}
	if res.Results[i].Error != "" {
		return res.Results[i].Error
	}
	if res.Results[i].Actual != "" {
		return "observed: " + res.Results[i].Actual
	}
	return "check did not pass"
}
