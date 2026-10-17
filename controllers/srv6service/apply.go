// SPDX-License-Identifier: Apache-2.0
//
// Apply stage, T380/T381: apply every node via the executor client in plan
// order; a node failure rolls back on EVERY node (the plan's rollback ops),
// sets a terminal-shaped ApplyFailed naming the failed node, and releases the
// claims — no device state of this service is left half-applied.
package srv6service

import (
	"context"
	"fmt"
	"sort"

	"github.com/go-logr/logr"
	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
)

// applyPlan applies the plan's nodes in plan order. The first failing node
// aborts the stage and is named; callers roll back and refuse.
func applyPlan(ctx context.Context, ex Executor, plan *fabricplan.Plan, order []string) (string, error) {
	for _, node := range order {
		np := plan.Nodes[node]
		res, err := ex.Apply(ctx, node, np.Ops)
		if err != nil {
			return node, err
		}
		if res != nil && !res.OK {
			return node, fmt.Errorf("node %s rejected its plan: %s", node, firstApplyError(res))
		}
	}
	return "", nil
}

func firstApplyError(res *executorclient.ApplyResult) string {
	for _, r := range res.Results {
		if r.Error != "" {
			return r.Error
		}
	}
	return "unknown error"
}

// rollbackPlan runs the plan's rollback ops on EVERY node (T381), best
// effort, in plan order. It returns the first error so callers can tell a
// node that stayed dirty; it never aborts the walk early (every node gets
// its rollback attempt regardless of earlier failures).
func rollbackPlan(ctx context.Context, ex Executor, plan *fabricplan.Plan, order []string, log logr.Logger) error {
	var firstErr error
	nodes := append([]string(nil), order...)
	sort.Strings(nodes)
	for _, node := range nodes {
		np := plan.Nodes[node]
		if len(np.Rollback) == 0 {
			continue
		}
		res, err := ex.Apply(ctx, node, np.Rollback)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if res != nil && !res.OK {
			if firstErr == nil {
				firstErr = fmt.Errorf("node %s rejected its rollback: %s", node, firstApplyError(res))
			}
		}
	}
	return firstErr
}

// applyFailedRefusal is the ApplyFailed refusal naming the failed node.
func applyFailedRefusal(node string, err error) *Refusal {
	return &Refusal{
		Reason:  reasons.ReasonApplyFailed,
		Message: fmt.Sprintf("node %s failed to apply: %v (rolled back on every node)", node, err),
		Kind:    refusalApply,
	}
}

// executorPermanent reports a refusal the executor will repeat every time
// (an unknown node, a malformed op): for finalization that means the node
// holds nothing of ours and is clean.
func executorPermanent(err error) bool { return executorclient.IsPermanent(err) }
