// SPDX-License-Identifier: Apache-2.0
//
// Deletion tests, T394 (finalizer.go finalizeDelete, contract §5): a deleted
// service rolls back on EVERY node first, releases the claims only once every
// node is clean, and only then drops the finalizer (the object goes away).
// A node whose rollback cannot be confirmed (transport failure — the executor
// may simply be restarting) keeps the finalizer AND the claims under a
// Finalizing condition naming the node, with a requeue; once the node heals,
// the same path completes the deletion.
package srv6service

import (
	"context"
	"errors"
	"strings"
	"testing"

	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// convergedForDelete stores a converged, finalizer-carrying service and
// returns its previous plan (the render the rollback is checked against).
func convergedForDelete(t *testing.T, c client.Client, name, corrID string) (prevPlan *fabricplan.Plan) {
	t.Helper()
	svc := testService(name, corrID)
	alloc := testAllocation(t, svc)
	prevPlan = mustReplan(t, svc, alloc)
	appliedStatusFor(svc, alloc, PlanHashes(prevPlan), 1)
	svc.Finalizers = append(svc.Finalizers, agenticnetopsv1alpha1.SRv6Finalizer)
	if err := c.Create(context.Background(), svc); err != nil {
		t.Fatalf("create: %v", err)
	}
	return prevPlan
}

// markDeleted deletes the object through the client; the finalizer holds it
// in the deleting state.
func markDeleted(t *testing.T, c client.Client, name string) {
	t.Helper()
	var svc agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey(name), &svc); err != nil {
		t.Fatalf("get before delete: %v", err)
	}
	if err := c.Delete(context.Background(), &svc); err != nil {
		t.Fatalf("delete: %v", err)
	}
}

// TestDeleteRollsBackEveryNodeReleasesAndFinalizes is T394's clean half.
func TestDeleteRollsBackEveryNodeReleasesAndFinalizes(t *testing.T) {
	const name = "del-clean"
	const corrID = "del-clean"
	c := newTestClient(t)
	prevPlan := convergedForDelete(t, c, name, corrID)
	testClaims(t, c, corrID)
	markDeleted(t, c, name)

	ex := &recordingExecutor{}
	r := testReconciler(t, c, ex, goodPins())
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: testKey(name)}); err != nil {
		t.Fatalf("reconcile: %v", err)
	}

	// Rollback ran on EVERY node, sending the previous render's inverse.
	for _, node := range []string{"leaf01", "leaf02"} {
		calls := ex.appliesTo(node)
		if len(calls) != 1 {
			t.Fatalf("%s saw %d rollback calls, want 1", node, len(calls))
		}
		if canonicalOp(calls[0].Ops[0]) != canonicalOp(prevPlan.Nodes[node].Rollback[0]) {
			t.Errorf("%s rollback is not the previous render's inverse: %s", node, canonicalOp(calls[0].Ops[0]))
		}
	}
	// Claims released, then the finalizer removed: the object is gone.
	if n := countClaims(t, c); n != 0 {
		t.Errorf("%d claims left after a clean delete, want all released", n)
	}
	var gone agenticnetopsv1alpha1.SRv6Service
	err := c.Get(context.Background(), testKey(name), &gone)
	if !apierrors.IsNotFound(err) {
		t.Errorf("object still present after the finalizer dropped (err = %v), want NotFound", err)
	}
}

// TestDeleteKeepsFinalizerWhileNodeUnreachable is T394's dirty half.
func TestDeleteKeepsFinalizerWhileNodeUnreachable(t *testing.T) {
	const name = "del-dirty"
	const corrID = "del-dirty"
	c := newTestClient(t)
	prevPlan := convergedForDelete(t, c, name, corrID)
	testClaims(t, c, corrID)
	markDeleted(t, c, name)

	ex := &recordingExecutor{}
	ex.applyFn = func(call execCall, nth int) (*executorclient.ApplyResult, error) {
		if call.Node == "leaf02" {
			// transport failure, NOT a permanent refusal: the node may come
			// back, so the rollback stays pending
			return nil, errors.New("dial tcp 10.0.0.2:50051: connection refused")
		}
		return applyOKResult(call.Node), nil
	}
	r := testReconciler(t, c, ex, goodPins())
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: testKey(name)})
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if res.RequeueAfter <= 0 {
		t.Error("dirty delete returned without a requeue; the rollback must be retried")
	}

	// The Finalizing condition names the unreachable node.
	var got agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey(name), &got); err != nil {
		t.Fatalf("get: %v", err)
	}
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Reason != reasons.ReasonFinalizing {
		t.Fatalf("Ready reason = %+v, want %s", cond, reasons.ReasonFinalizing)
	}
	if !strings.Contains(cond.Message, "leaf02") || !strings.Contains(cond.Message, "finalizer and claims kept") {
		t.Errorf("message %q must name the node and the kept state", cond.Message)
	}
	// The other node's rollback still ran; the walk never stopped early.
	if calls := ex.appliesTo("leaf01"); len(calls) != 1 {
		t.Errorf("leaf01 rollback calls = %d, want 1", len(calls))
	}
	// Finalizer AND claims kept while the node is dirty.
	if !hasSRv6Finalizer(&got) {
		t.Error("finalizer removed while leaf02's rollback is unconfirmed")
	}
	if n := countClaims(t, c); n != 3 {
		t.Errorf("%d claims left, want all 3 kept while the rollback is unconfirmed", n)
	}
	_ = prevPlan
}

// TestDeleteCompletesOnceTheNodeHeals is T394's recovery half.
func TestDeleteCompletesOnceTheNodeHeals(t *testing.T) {
	const name = "del-heal"
	const corrID = "del-heal"
	c := newTestClient(t)
	convergedForDelete(t, c, name, corrID)
	testClaims(t, c, corrID)
	markDeleted(t, c, name)

	blocked := &recordingExecutor{}
	blocked.applyFn = func(call execCall, nth int) (*executorclient.ApplyResult, error) {
		if call.Node == "leaf02" {
			return nil, errors.New("grpc transport unavailable")
		}
		return applyOKResult(call.Node), nil
	}
	r := testReconciler(t, c, blocked, goodPins())
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: testKey(name)}); err != nil {
		t.Fatalf("dirty reconcile: %v", err)
	}

	// The node heals: the next reconcile rolls it back and completes.
	healed := &recordingExecutor{}
	r2 := testReconciler(t, c, healed, goodPins())
	if _, err := r2.Reconcile(context.Background(), ctrl.Request{NamespacedName: testKey(name)}); err != nil {
		t.Fatalf("healed reconcile: %v", err)
	}
	if calls := healed.appliesTo("leaf02"); len(calls) != 1 {
		t.Errorf("healed rollback calls for leaf02 = %d, want 1", len(calls))
	}
	if n := countClaims(t, c); n != 0 {
		t.Errorf("%d claims left after the healed delete, want all released", n)
	}
	var gone agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey(name), &gone); !apierrors.IsNotFound(err) {
		t.Errorf("object still present after the healed delete (err = %v), want NotFound", err)
	}
}
