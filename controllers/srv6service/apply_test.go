// SPDX-License-Identifier: Apache-2.0
//
// Apply-stage tests, T380: the plan is applied on EVERY node in plan order;
// when one node fails, the rollback runs on EVERY node, the refusal is the
// ApplyFailed naming the failed node, and the claims are released — no
// device state of this service is left half-applied and nothing stays
// claimed for a service that is not applied.
package srv6service

import (
	"context"
	"strings"
	"testing"

	"github.com/go-logr/logr"
	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/reasons"
	ctrl "sigs.k8s.io/controller-runtime"
)

// TestApplyPlanAppliesEveryNodeInOrder is T380's order half.
func TestApplyPlanAppliesEveryNodeInOrder(t *testing.T) {
	svc := testService("apply-order", "apply-order-1")
	alloc := testAllocation(t, svc)
	plan := mustReplan(t, svc, alloc)
	ex := &recordingExecutor{}

	failed, err := applyPlan(context.Background(), ex, plan, PlanOrder(plan))
	if err != nil || failed != "" {
		t.Fatalf("applyPlan = (%q, %v), want success", failed, err)
	}
	calls := ex.applyCalls()
	if len(calls) != 2 || calls[0].Node != "leaf01" || calls[1].Node != "leaf02" {
		t.Fatalf("apply calls = %+v, want leaf01 then leaf02 (every node, plan order)", calls)
	}
	for i, node := range []string{"leaf01", "leaf02"} {
		if canonicalOp(calls[i].Ops[0]) != canonicalOp(plan.Nodes[node].Ops[0]) {
			t.Errorf("call %d sent different ops than the plan renders for %s", i, node)
		}
	}
}

// TestApplyPlanNamesTheFailedNode is T380's failure half, unit level.
func TestApplyPlanNamesTheFailedNode(t *testing.T) {
	svc := testService("apply-fail", "apply-fail-1")
	plan := mustReplan(t, svc, testAllocation(t, svc))
	ex := &recordingExecutor{}
	ex.applyFn = func(call execCall, nth int) (*executorclient.ApplyResult, error) {
		if call.Node == "leaf02" {
			return applyFailResult(call.Node, "gcu: table Vrf7 wedged"), nil
		}
		return applyOKResult(call.Node), nil
	}
	failed, err := applyPlan(context.Background(), ex, plan, PlanOrder(plan))
	if failed != "leaf02" || err == nil {
		t.Fatalf("applyPlan = (%q, %v), want leaf02 with an error", failed, err)
	}
	// Every node was still attempted (leaf01 before the failure).
	nodes := map[string]bool{}
	for _, call := range ex.applyCalls() {
		nodes[call.Node] = true
	}
	if !nodes["leaf01"] || !nodes["leaf02"] {
		t.Errorf("applied %v, want both nodes attempted", nodes)
	}

	// The refusal names the node in the ApplyFailed vocabulary.
	ref := applyFailedRefusal(failed, err)
	if ref.Reason != reasons.ReasonApplyFailed {
		t.Errorf("refusal reason = %q, want %q", ref.Reason, reasons.ReasonApplyFailed)
	}
	if !strings.Contains(ref.Message, "leaf02") {
		t.Errorf("refusal message %q must name the failed node", ref.Message)
	}
}

// TestRollbackRunsOnEveryNode is the T380/T381 rollback rule: one node's
// rollback failing never stops the walk — every node still gets its attempt.
func TestRollbackRunsOnEveryNode(t *testing.T) {
	svc := testService("apply-rb", "apply-rb-1")
	plan := mustReplan(t, svc, testAllocation(t, svc))
	ex := &recordingExecutor{}
	if err := rollbackPlan(context.Background(), ex, plan, PlanOrder(plan), logr.Discard()); err != nil {
		t.Fatalf("rollbackPlan: %v", err)
	}
	calls := ex.applyCalls()
	if len(calls) != 2 {
		t.Fatalf("rollback calls = %d, want one per node", len(calls))
	}
	for i, node := range []string{"leaf01", "leaf02"} {
		if canonicalOp(calls[i].Ops[0]) != canonicalOp(plan.Nodes[node].Rollback[0]) {
			t.Errorf("rollback call %d did not send %s's rollback ops", i, node)
		}
	}

	// A failing rollback still walks on: the SECOND node's attempt happens.
	ex2 := &recordingExecutor{}
	ex2.applyFn = func(call execCall, nth int) (*executorclient.ApplyResult, error) {
		if call.Node == "leaf01" {
			return applyFailResult(call.Node, "unreachable"), nil
		}
		return applyOKResult(call.Node), nil
	}
	if err := rollbackPlan(context.Background(), ex2, plan, PlanOrder(plan), logr.Discard()); err == nil {
		t.Fatal("rollbackPlan reported no error though leaf01's rollback failed")
	}
	if calls := ex2.appliesTo("leaf02"); len(calls) != 1 {
		t.Errorf("leaf02 rollback attempts = %d, want 1 (the walk never aborts early)", len(calls))
	}
}

// TestApplyFailureRollsBackEveryNodeAndReleasesClaims is T380 end to end:
// leaf02's apply fails inside the pipeline; leaf01 (already applied) and
// leaf02 are BOTH rolled back, the refusal names leaf02, and the claims are
// released.
func TestApplyFailureRollsBackEveryNodeAndReleasesClaims(t *testing.T) {
	const corrID = "apply-fail-live"
	const name = "apply-fail-live"
	svc := testService(name, corrID)
	failing := mustReplan(t, svc, testAllocation(t, svc)).Nodes["leaf02"].Ops[0]

	c := newTestClient(t, svc)
	testClaims(t, c, corrID)
	ex := &recordingExecutor{}
	ex.applyFn = func(call execCall, nth int) (*executorclient.ApplyResult, error) {
		if call.Node == "leaf02" && canonicalOp(call.Ops[0]) == canonicalOp(failing) {
			return applyFailResult(call.Node, "gcu: kernel said no"), nil
		}
		return applyOKResult(call.Node), nil
	}

	r := testReconciler(t, c, ex, goodPins())
	// Reconcile exactly twice: the first pass adds the finalizer, the second
	// claims, applies, fails and refuses. Driving it by hand keeps the
	// post-failure state observable before any later reconcile re-claims.
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: testKey(name)}); err != nil {
		t.Fatalf("finalizer reconcile: %v", err)
	}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: testKey(name)}); err != nil {
		t.Fatalf("apply reconcile: %v", err)
	}
	var got agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey(name), &got); err != nil {
		t.Fatalf("get: %v", err)
	}
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Reason != reasons.ReasonApplyFailed {
		t.Fatalf("Ready reason = %+v, want %s", cond, reasons.ReasonApplyFailed)
	}
	if !strings.Contains(cond.Message, "leaf02") {
		t.Errorf("refusal message %q must name the failed node", cond.Message)
	}
	// The already-applied leaf01 was rolled back too, and leaf02's rollback
	// ran after its failure: every node, in both directions.
	if calls := ex.appliesTo("leaf01"); len(calls) != 2 {
		t.Errorf("leaf01 apply calls = %d, want plan + rollback", len(calls))
	}
	if calls := ex.appliesTo("leaf02"); len(calls) != 2 {
		t.Errorf("leaf02 apply calls = %d, want failed plan + rollback", len(calls))
	}
	// The claims are released: nothing of this service is left claimed.
	if n := countClaims(t, c); n != 0 {
		t.Errorf("%d claims left after the apply failure, want all released", n)
	}
	if got.Status.Allocations != nil {
		t.Error("status.allocations recorded for a service that failed to apply")
	}
}
