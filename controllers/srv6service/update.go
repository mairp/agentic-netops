// SPDX-License-Identifier: Apache-2.0
//
// Update path, T613 (contracts/srv6service-crd.md §3a). Tenant, construct
// and signalling are immutable; any other field change re-enters the
// pipeline (C1-C8 re-run on every reconcile) and, when the fresh render
// differs from the applied one, the change is driven HERE:
//
//  1. re-render the PREVIOUS plan from status.appliedSpec and the UNCHANGED
//     allocations — the renderer is pure (pkg/fabricplan.ForSRv6Service), so
//     the re-render is byte-identical to what the last apply sent;
//  2. diff it per node against the new plan;
//  3. drive the removal: on every node whose previous render lost items, the
//     previous plan's rollback runs BEFORE the new plan (the rollback is the
//     per-item inverse of the previous render; the new plan re-adds every
//     item it still contains, so shared state is only ever dark for the
//     diff's own duration);
//  4. apply the new plan and verify it (locator probe first, then checks);
//  5. only once verified, store the new status.appliedSpec plus the new
//     per-node hashes and the Verified outcome for the new generation.
//
// A failed update rolls EVERY node back to the previous plan — the previous
// rollback, then the previous plan's own ops re-applied — and refuses
// ApplyFailed naming the failed node. status.appliedSpec keeps the previous
// render, so the next reconcile re-drives the same update instead of
// mistaking a half-updated device for the target state. Claims are NOT
// released by an update: the addressing identifiers do not change (only a
// changed spec.vlan would, and that is re-claimed by the pipeline first).
package srv6service

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// canonicalOp is an op's canonical JSON form — the diff key. Two renders of
// the same item produce the same canonical form; any changed byte (a new
// via address, a new gateway) is a different item.
func canonicalOp(op fabricplan.Op) string {
	b, err := json.Marshal(op)
	if err != nil {
		return fmt.Sprintf("unencodable:%+v", op)
	}
	return string(b)
}

// diffPlans returns, per node, the PREVIOUS plan's ops the new plan no
// longer contains (the items to remove). Nodes with nothing removed are
// absent from the result, so the removal drive only touches the nodes whose
// rendered state actually changed.
func diffPlans(prev, next *fabricplan.Plan) map[string][]fabricplan.Op {
	out := map[string][]fabricplan.Op{}
	for node, prevNode := range prev.Nodes {
		kept := map[string]bool{}
		if newNode, ok := next.Nodes[node]; ok {
			for _, op := range newNode.Ops {
				kept[canonicalOp(op)] = true
			}
		}
		var removed []fabricplan.Op
		for _, op := range prevNode.Ops {
			if !kept[canonicalOp(op)] {
				removed = append(removed, op)
			}
		}
		if len(removed) > 0 {
			out[node] = removed
		}
	}
	return out
}

// renderAppliedPlan re-renders the plan of what IS applied, from
// status.appliedSpec and the unchanged allocations. It returns nil (with no
// error) when nothing is applied yet — there is nothing to diff against and
// the plain apply path owns the first application.
func renderAppliedPlan(applied *v1alpha1.SRv6ServiceSpec, alloc *Allocation, facts SiteFacts) (*fabricplan.Plan, error) {
	if applied == nil {
		return nil, nil
	}
	return BuildPlan(&v1alpha1.SRv6Service{Spec: *applied}, alloc, facts)
}

// applyUpdate drives one changed render (§3a): per node the removal first,
// then the new plan, verify, and only then the new status.appliedSpec. It
// returns nil once the new render is applied, verified AND recorded.
func (r *Reconciler) applyUpdate(ctx context.Context, svc *v1alpha1.SRv6Service, alloc *Allocation,
	plan *fabricplan.Plan, order []string, hashes map[string]string) *Refusal {

	prev, err := renderAppliedPlan(svc.Status.AppliedSpec, alloc, r.Facts)
	if err != nil {
		// The applied spec must always render (it rendered when it was
		// applied); failing here is an invariant breach, not operator error.
		return &Refusal{
			Reason:  reasons.ReasonApplyFailed,
			Message: "previous plan could not be re-rendered from status.appliedSpec: " + err.Error(),
			Kind:    refusalApply,
		}
	}
	if prev == nil {
		// Nothing applied yet: no removal exists, the plain apply path owns
		// the first application.
		return nil
	}

	// The removal: on every node that lost items, the previous plan's
	// rollback runs BEFORE the new plan (§3a). Nodes whose render is
	// unchanged are not touched here.
	removals := diffPlans(prev, plan)
	nodes := make([]string, 0, len(removals))
	for node := range removals {
		nodes = append(nodes, node)
	}
	sort.Strings(nodes)
	for _, node := range nodes {
		if _, aerr := r.Executor.Apply(ctx, node, prev.Nodes[node].Rollback); aerr != nil {
			return applyFailedRefusal(node, aerr)
		}
	}

	// The new plan.
	failed, aerr := applyPlan(ctx, r.Executor, plan, order)
	if aerr != nil {
		// Failed update (§3a): roll every node back to the previous plan —
		// the previous rollback, then the previous plan's own ops — and
		// refuse ApplyFailed naming the node. status.appliedSpec is NOT
		// touched: it still names the render the device was restored to.
		if rberr := rollbackPlan(ctx, r.Executor, prev, PlanOrder(prev), r.Log); rberr != nil {
			r.Log.Error(rberr, "update rollback left nodes dirty", "srv6service", client.ObjectKeyFromObject(svc))
		}
		if _, perr := applyPlan(ctx, r.Executor, prev, PlanOrder(prev)); perr != nil {
			r.Log.Error(perr, "update restore could not re-apply the previous plan", "srv6service",
				client.ObjectKeyFromObject(svc), "failedNode", failed)
		}
		return applyFailedRefusal(failed, aerr)
	}

	// Verify the new render (locator probe first, then checks).
	nodeStatus, vref := verifyPlan(ctx, r.Executor, plan, order, r.Facts.Locators)
	svc.Status.Nodes = nodeStatus
	if vref != nil {
		return vref
	}

	// Verified: NOW the new state is recorded — applied spec, per-node
	// hashes and the Verified outcome for the new generation.
	base := svc.DeepCopy()
	setReadyOutcome(&svc.Status, svc.Generation, hashes, svc.Spec.DeepCopy(),
		correlationID(svc), svc.Status.ActivePath, alloc.Allocations)
	if err := r.Status().Patch(ctx, svc, client.MergeFrom(base)); err != nil {
		return &Refusal{
			Reason:  reasons.ReasonApplyFailed,
			Message: "update verified but the status write failed: " + err.Error(),
			Kind:    refusalApply,
		}
	}
	return nil
}
