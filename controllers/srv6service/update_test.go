// SPDX-License-Identifier: Apache-2.0
//
// Update tests, T612 (update.go, contracts/srv6service-crd.md §3a). The
// pipeline re-runs C1-C8 on every reconcile; when the fresh render differs
// from status.appliedSpec's re-render, the change is driven by r.applyUpdate:
//
//   - a preferred-spine change (spine01 -> spine02) removes leaf01's locator
//     pin AND preferred pin (2 ops) and leaf02's locator pin (1 op);
//   - per changed node the PREVIOUS rollback runs BEFORE the new plan;
//   - the new render is verified, and only then are status.appliedSpec and
//     status.configHashes (and the Verified outcome for the new generation)
//     stored; the claims are untouched;
//   - a failed update rolls EVERY node back to the previous plan and refuses
//     ApplyFailed naming the failed node, with status.appliedSpec still
//     naming the render the device was restored to;
//   - nothing applied yet is a no-op here (the plain apply path owns it);
//   - a MUTABLE-field change still re-validates the site at the new
//     generation: moving an attachment to a spine is refused InvalidSite
//     before any device work.
package srv6service

import (
	"context"
	"reflect"
	"strings"
	"testing"

	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/reasons"
	ctrl "sigs.k8s.io/controller-runtime"
)

// steeredTo copies svc with the preferred spine replaced.
func steeredTo(svc *agenticnetopsv1alpha1.SRv6Service, spine string, gen int64) *agenticnetopsv1alpha1.SRv6Service {
	next := svc.DeepCopy()
	next.Spec.Path.PreferredSpine = spine
	next.Generation = gen
	return next
}

// appliedStatusFor builds a converged Ready status naming the given applied
// spec and per-node hashes.
func appliedStatusFor(svc *agenticnetopsv1alpha1.SRv6Service, alloc *Allocation,
	hashes map[string]string, gen int64) {
	svc.Status.AppliedSpec = svc.Spec.DeepCopy()
	svc.Status.ConfigHashes = hashes
	svc.Status.CorrelationID = correlationID(svc)
	svc.Status.Allocations = alloc.Allocations
	setReadyOutcome(&svc.Status, gen, hashes, svc.Spec.DeepCopy(), correlationID(svc), svc.Spec.Path.PreferredSpine, alloc.Allocations)
}

// TestDiffPlansSpineChangeRemovesThePins is T612's diff shape: spine01 ->
// spine02 removes leaf01's locator-pin and preferred-pin and leaf02's
// locator-pin; spines carry no ops and appear nowhere.
func TestDiffPlansSpineChangeRemovesThePins(t *testing.T) {
	old := testService("upd-diff", "upd-diff-1")
	alloc := testAllocation(t, old)
	prev := mustReplan(t, old, alloc)
	next := mustReplan(t, steeredTo(old, "spine02", 2), alloc)

	removals := diffPlans(prev, next)
	if got := len(removals["leaf01"]); got != 2 {
		t.Errorf("leaf01 removed ops = %d, want 2 (locator-pin + preferred-pin)", got)
	}
	if got := len(removals["leaf02"]); got != 1 {
		t.Errorf("leaf02 removed ops = %d, want 1 (locator-pin)", got)
	}
	for _, spine := range []string{"spine01", "spine02"} {
		if _, ok := removals[spine]; ok {
			t.Errorf("%s in the removal map; spines carry no rendered ops", spine)
		}
	}
	// The removed leaf01 items ARE the spine01-pinned ones.
	for _, op := range removals["leaf01"] {
		if !strings.Contains(canonicalOp(op), "2001:db8:1::3") {
			t.Errorf("removed op %s is not pinned via spine01's leg", canonicalOp(op))
		}
	}
	// A spine change is the ONLY difference: leaf01's other 5 ops survive.
	if len(prev.Nodes["leaf01"].Ops) != 7 || len(next.Nodes["leaf01"].Ops) != 7 {
		t.Errorf("leaf01 op counts %d -> %d, want 7 -> 7 (same items, new via)",
			len(prev.Nodes["leaf01"].Ops), len(next.Nodes["leaf01"].Ops))
	}
}

// TestApplyUpdateDrivesRemovalThenNewPlan is T612's happy path.
func TestApplyUpdateDrivesRemovalThenNewPlan(t *testing.T) {
	const name = "upd-live"
	old := testService(name, "upd-live-1")
	alloc := testAllocation(t, old)
	prevPlan := mustReplan(t, old, alloc)
	prevHashes := PlanHashes(prevPlan)

	appliedStatusFor(old, alloc, prevHashes, 1)
	newSvc := steeredTo(old, "spine02", 2)
	newPlan := mustReplan(t, newSvc, alloc)
	newHashes := PlanHashes(newPlan)

	c := newTestClient(t, newSvc)
	testClaims(t, c, correlationID(old))
	ex := &recordingExecutor{}
	r := testReconciler(t, c, ex, goodPins())

	ref := r.applyUpdate(context.Background(), newSvc, alloc, newPlan, PlanOrder(newPlan), newHashes)
	if ref != nil {
		t.Fatalf("applyUpdate refused: %s (%s)", ref.Message, ref.Reason)
	}

	// Per changed node: the PREVIOUS rollback first, then the new plan.
	for _, node := range []string{"leaf01", "leaf02"} {
		calls := ex.appliesTo(node)
		if len(calls) != 2 {
			t.Fatalf("%s saw %d calls, want rollback(prev) then apply(new)", node, len(calls))
		}
		if canonicalOp(calls[0].Ops[0]) != canonicalOp(prevPlan.Nodes[node].Rollback[0]) {
			t.Errorf("%s call 0 is not the previous rollback: %s", node, canonicalOp(calls[0].Ops[0]))
		}
		if canonicalOp(calls[1].Ops[0]) != canonicalOp(newPlan.Nodes[node].Ops[0]) {
			t.Errorf("%s call 1 is not the new plan: %s", node, canonicalOp(calls[1].Ops[0]))
		}
	}
	// The new render is verified on every node: locator probe FIRST, then
	// the checks — two Verify round trips per node.
	if ex.verifyCount() != 2*len(newSvc.Spec.Attachments) {
		t.Errorf("verify calls = %d, want locator + checks per attachment node", ex.verifyCount())
	}

	// Only once verified is the new state recorded, for the new generation.
	var got agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey(name), &got); err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Status.AppliedSpec == nil || !reflect.DeepEqual(*got.Status.AppliedSpec, newSvc.Spec) {
		t.Error("status.appliedSpec does not name the new spec after a verified update")
	}
	if !reflect.DeepEqual(got.Status.ConfigHashes, newHashes) {
		t.Errorf("status.configHashes = %v, want the new %v", got.Status.ConfigHashes, newHashes)
	}
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Reason != reasons.ReasonVerified || cond.ObservedGeneration != 2 {
		t.Errorf("Ready = %+v, want Verified at generation 2", cond)
	}
	// The claims are NOT released by an update: the identifiers do not change.
	if n := countClaims(t, c); n != 3 {
		t.Errorf("%d claims after the update, want the 3 untouched", n)
	}
}

// TestApplyUpdateFailureRollsEveryNodeBack is T612's failure half.
func TestApplyUpdateFailureRollsEveryNodeBack(t *testing.T) {
	const name = "upd-fail"
	old := testService(name, "upd-fail-1")
	alloc := testAllocation(t, old)
	prevPlan := mustReplan(t, old, alloc)
	prevHashes := PlanHashes(prevPlan)
	appliedStatusFor(old, alloc, prevHashes, 1)

	newSvc := steeredTo(old, "spine02", 2)
	newPlan := mustReplan(t, newSvc, alloc)

	c := newTestClient(t, newSvc)
	testClaims(t, c, correlationID(old))
	ex := &recordingExecutor{}
	ex.applyFn = func(call execCall, nth int) (*executorclient.ApplyResult, error) {
		if call.Node == "leaf02" && canonicalOp(call.Ops[0]) == canonicalOp(newPlan.Nodes["leaf02"].Ops[0]) {
			return applyFailResult(call.Node, "gcu: spine02 pin rejected"), nil
		}
		return applyOKResult(call.Node), nil
	}
	r := testReconciler(t, c, ex, goodPins())

	ref := r.applyUpdate(context.Background(), newSvc, alloc, newPlan, PlanOrder(newPlan), PlanHashes(newPlan))
	if ref == nil || ref.Reason != reasons.ReasonApplyFailed {
		t.Fatalf("refusal = %+v, want ApplyFailed", ref)
	}
	if !strings.Contains(ref.Message, "leaf02") {
		t.Errorf("refusal message %q must name the failed node", ref.Message)
	}

	// EVERY node is back on the previous plan: removal rollback, failed new
	// apply (leaf02 only), then rollback(prev) again and prev re-applied.
	for _, node := range []string{"leaf01", "leaf02"} {
		calls := ex.appliesTo(node)
		if len(calls) != 4 {
			t.Fatalf("%s saw %d calls, want [rb(prev), apply(new), rb(prev), apply(prev)]", node, len(calls))
		}
		wantPrevOp := canonicalOp(prevPlan.Nodes[node].Ops[0])
		if canonicalOp(calls[3].Ops[0]) != wantPrevOp {
			t.Errorf("%s final call is not the previous plan re-applied: %s", node, canonicalOp(calls[3].Ops[0]))
		}
	}
	// status.appliedSpec still names the render the device was restored to,
	// so the next reconcile re-drives this update instead of mistaking a
	// half-updated device for the target state.
	var got agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey(name), &got); err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Status.AppliedSpec == nil || !reflect.DeepEqual(*got.Status.AppliedSpec, old.Spec) {
		t.Error("status.appliedSpec changed on a failed update; it must keep the previous render")
	}
	if !reflect.DeepEqual(got.Status.ConfigHashes, prevHashes) {
		t.Errorf("status.configHashes = %v, want the previous %v kept", got.Status.ConfigHashes, prevHashes)
	}
}

// TestApplyUpdateIsNoopWhenNothingApplied is T612's guard: with no
// status.appliedSpec there is nothing to diff against — no device call, no
// refusal, no status write.
func TestApplyUpdateIsNoopWhenNothingApplied(t *testing.T) {
	svc := testService("upd-noop", "upd-noop-1")
	svc.Generation = 3
	alloc := testAllocation(t, svc)
	plan := mustReplan(t, svc, alloc)

	c := newTestClient(t, svc)
	ex := &recordingExecutor{}
	r := testReconciler(t, c, ex, goodPins())

	if ref := r.applyUpdate(context.Background(), svc, alloc, plan, PlanOrder(plan),
		PlanHashes(plan)); ref != nil {
		t.Fatalf("applyUpdate refused with nothing applied: %s", ref.Message)
	}
	if calls := ex.applyCalls(); len(calls) != 0 {
		t.Errorf("executor saw %d apply calls with nothing applied, want 0", len(calls))
	}
	if ex.verifyCount() != 0 {
		t.Errorf("executor saw %d verify calls with nothing applied, want 0", ex.verifyCount())
	}
	// The status write path was not taken: no Ready condition appeared.
	var got agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey("upd-noop"), &got); err != nil {
		t.Fatalf("get: %v", err)
	}
	if cond := readyCondition(&got.Status); cond != nil {
		t.Errorf("Ready condition %+v appeared; the no-op must not write status", cond)
	}
}

// TestMutableFieldChangeRevalidatesSite is T612's pipeline half: a mutable
// change re-enters the pipeline at the new generation, and C1 runs again —
// moving an attachment onto a spine is refused before any device work.
func TestMutableFieldChangeRevalidatesSite(t *testing.T) {
	const name = "upd-c1"
	old := testService(name, "upd-c1-1")
	alloc := testAllocation(t, old)
	appliedStatusFor(old, alloc, PlanHashes(mustReplan(t, old, alloc)), 1)

	mutated := old.DeepCopy()
	mutated.Spec.Attachments[0].Node = "spine01" // C1: attachment nodes are leaves
	mutated.Generation = 2

	c := newTestClient(t, mutated)
	testClaims(t, c, correlationID(old))
	ex := &recordingExecutor{}
	r := testReconciler(t, c, ex, goodPins())

	// The first reconcile adds the finalizer; the second hits C1.
	_, _ = r.Reconcile(context.Background(), ctrl.Request{NamespacedName: testKey(name)})
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: testKey(name)}); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	var got agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey(name), &got); err != nil {
		t.Fatalf("get: %v", err)
	}
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Reason != reasons.ReasonInvalidSite {
		t.Fatalf("Ready reason = %+v, want %s from the C1 re-run", cond, reasons.ReasonInvalidSite)
	}
	for _, want := range []string{"leaf", "spine01"} {
		if !strings.Contains(cond.Message, want) {
			t.Errorf("message %q must name %q", cond.Message, want)
		}
	}
	// Refused before any device work or claim churn.
	if calls := ex.applyCalls(); len(calls) != 0 {
		t.Errorf("executor saw %d apply calls after the C1 refusal, want 0", len(calls))
	}
	if n := countClaims(t, c); n != 3 {
		t.Errorf("%d claims after the C1 refusal, want the 3 kept", n)
	}
	// The stale applied spec survives: the site must be fixed before the
	// update path can drive anything.
	if got.Status.AppliedSpec == nil || !reflect.DeepEqual(*got.Status.AppliedSpec, old.Spec) {
		t.Error("status.appliedSpec changed on a refused change")
	}
}
