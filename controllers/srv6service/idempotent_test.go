// SPDX-License-Identifier: Apache-2.0
//
// Idempotence tests, T390 (controller.go apply gate): once the rendered
// hashes match status.configHashes the apply stage is skipped entirely — a
// second unchanged reconcile issues ZERO device writes while the steady-state
// verify keeps running and Ready stays True.
package srv6service

import (
	"context"
	"testing"
	"time"

	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

// TestSecondReconcileWithoutChangeAppliesNothing is T390.
func TestSecondReconcileWithoutChangeAppliesNothing(t *testing.T) {
	const name = "idem-1"
	const corrID = "idem-1"
	c := newTestClient(t, testService(name, corrID))
	testClaims(t, c, corrID)

	ex := &recordingExecutor{}
	got := convergeService(t, c, ex, goodPins(), name)
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Status != "True" {
		t.Fatalf("first reconcile did not converge Ready: %+v", cond)
	}
	firstApplies := len(ex.applyCalls())
	if firstApplies == 0 {
		t.Fatal("the first reconcile never applied; the test is vacuous")
	}
	if got.Status.ConfigHashes == nil || len(got.Status.ConfigHashes) == 0 {
		t.Fatal("no status.configHashes recorded; the apply gate could never trip")
	}

	// The steady-state resync: the SAME spec, hashes equal → no apply, but
	// verify still proves the running config.
	beforeVerifies := ex.verifyCount()
	r := testReconciler(t, c, ex, goodPins())
	for i := 0; i < 2; i++ {
		if _, err := r.Reconcile(context.Background(),
			ctrl.Request{NamespacedName: testKey(name)}); err != nil {
			t.Fatalf("steady-state reconcile %d: %v", i, err)
		}
	}
	if applies := len(ex.applyCalls()); applies != firstApplies {
		t.Errorf("apply calls grew %d -> %d with no spec change; the apply gate must skip unchanged renders",
			firstApplies, applies)
	}
	for _, node := range []string{"leaf01", "leaf02"} {
		// exactly the first activation's single apply, nothing since
		if calls := ex.appliesTo(node); len(calls) != 1 {
			t.Errorf("%s was applied %d times, want only the first activation", node, len(calls))
		}
	}
	if ex.verifyCount() == beforeVerifies {
		t.Error("steady-state reconciles skipped verify; verify must keep running")
	}

	var after agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey(name), &after); err != nil {
		t.Fatalf("get: %v", err)
	}
	if cond := readyCondition(&after.Status); cond == nil || cond.Status != "True" {
		t.Errorf("Ready after steady-state reconciles = %+v, want True", cond)
	}
	if after.Status.DataPath == nil {
		t.Error("status.dataPath lost across the steady-state reconciles")
	}
}

// TestSecondReconcileOfUnchangedReadyWritesNoStatus is T388: a steady-state
// reconcile of an unchanged Ready service issues NO status patch. The clock
// seam is advanced past the resync interval before the second reconcile, so
// any re-stamp — a condition LastTransitionTime or status.dataPath.checkedAt
// — would show up as a later time AND as a status patch (a resourceVersion
// bump, and the self-caused watch event that made the old controller requeue
// itself every ~2 s). The test asserts none of that happens while verify
// still runs and Ready stays True.
func TestSecondReconcileOfUnchangedReadyWritesNoStatus(t *testing.T) {
	const name = "idem-nostatus"
	const corrID = "idem-nostatus"

	t0 := time.Now().UTC().Truncate(time.Second)
	t1 := t0.Add(10 * time.Minute) // well past the 5-minute resync: any re-stamp is visible
	prev := nowFunc
	nowFunc = func() time.Time { return t0 }
	t.Cleanup(func() { nowFunc = prev })

	var statusPatches int
	c := fake.NewClientBuilder().
		WithScheme(testScheme(t)).
		WithStatusSubresource(&agenticnetopsv1alpha1.SRv6Service{}).
		WithInterceptorFuncs(interceptor.Funcs{
			SubResourcePatch: func(ctx context.Context, cl client.Client, subResourceName string,
				obj client.Object, patch client.Patch, opts ...client.SubResourcePatchOption) error {
				if subResourceName == "status" {
					statusPatches++
				}
				return cl.SubResource(subResourceName).Patch(ctx, obj, patch, opts...)
			},
		}).
		WithObjects(testService(name, corrID)).
		Build()
	testClaims(t, c, corrID)

	ex := &recordingExecutor{}
	got := convergeService(t, c, ex, goodPins(), name)
	if cond := readyCondition(&got.Status); cond == nil || cond.Status != "True" {
		t.Fatalf("first reconcile did not converge Ready: %+v", cond)
	}
	if statusPatches == 0 {
		t.Fatal("the first converge never patched the status; the test is vacuous")
	}
	readyAt := readyCondition(&got.Status).LastTransitionTime
	degradedAt := metav1.Time{}
	for i := range got.Status.Conditions {
		if got.Status.Conditions[i].Type == ConditionDegraded {
			degradedAt = got.Status.Conditions[i].LastTransitionTime
		}
	}
	if degradedAt.IsZero() {
		t.Fatal("no Degraded condition after the first converge")
	}
	checkedAt := got.Status.DataPath.CheckedAt
	if checkedAt.IsZero() {
		t.Fatal("status.dataPath.checkedAt not set at first activation (T386)")
	}
	rvAfterFirst := got.ResourceVersion
	patchesAfterFirst := statusPatches

	// The steady-state resync: same spec, clock advanced past the interval.
	nowFunc = func() time.Time { return t1 }
	beforeVerifies := ex.verifyCount()
	r := testReconciler(t, c, ex, goodPins())
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: testKey(name)})
	if err != nil {
		t.Fatalf("steady-state reconcile: %v", err)
	}
	if res.RequeueAfter != resyncInterval {
		t.Errorf("steady-state RequeueAfter = %v, want the %v drift resync", res.RequeueAfter, resyncInterval)
	}

	var after agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey(name), &after); err != nil {
		t.Fatalf("get: %v", err)
	}
	if statusPatches != patchesAfterFirst {
		t.Errorf("the steady-state reconcile issued %d new status patch(es); an unchanged Ready service must patch nothing",
			statusPatches-patchesAfterFirst)
	}
	if after.ResourceVersion != rvAfterFirst {
		t.Errorf("resourceVersion moved %s -> %s on an unchanged service; the reconcile wrote a no-op status",
			rvAfterFirst, after.ResourceVersion)
	}
	if cond := readyCondition(&after.Status); cond == nil || cond.Status != "True" {
		t.Errorf("Ready after the steady-state reconcile = %+v, want True", cond)
	} else if !cond.LastTransitionTime.Time.Equal(readyAt.Time) {
		t.Errorf("Ready lastTransitionTime moved %v -> %v with no status change",
			readyAt.Time, cond.LastTransitionTime.Time)
	}
	for i := range after.Status.Conditions {
		if after.Status.Conditions[i].Type == ConditionDegraded &&
			!after.Status.Conditions[i].LastTransitionTime.Time.Equal(degradedAt.Time) {
			t.Errorf("Degraded lastTransitionTime moved %v -> %v with no status change",
				degradedAt.Time, after.Status.Conditions[i].LastTransitionTime.Time)
		}
	}
	if after.Status.DataPath == nil || !after.Status.DataPath.CheckedAt.Time.Equal(checkedAt.Time) {
		gotAt := "nil"
		if after.Status.DataPath != nil {
			gotAt = after.Status.DataPath.CheckedAt.String()
		}
		t.Errorf("status.dataPath.checkedAt moved %v -> %s; the probe stamp must survive the resync",
			checkedAt.Time, gotAt)
	}
	if ex.verifyCount() == beforeVerifies {
		t.Error("the steady-state reconcile skipped verify; the no-write guard must not skip the checks")
	}
}
