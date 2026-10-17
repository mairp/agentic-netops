// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"context"
	"strings"
	"testing"

	coordinationv1 "k8s.io/api/coordination/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func seedLease(t *testing.T, env *testEnv, kind, pool string, value int, correlationID string) *coordinationv1.Lease {
	t.Helper()
	lease := newLease(kind, pool, value, correlationID)
	if err := env.Client.Create(context.Background(), lease); err != nil {
		t.Fatalf("seed lease: %v", err)
	}
	return lease
}

// Mirrors agents/tests/unit/test_kuid_client.py::test_genid_allocation_falls_
// back_to_atomic_lease: the served claim fails, the fallback allocates the
// lowest free value through an atomic Lease create whose name embeds the
// value and whose annotations record correlation id and allocated id.
func TestLeaseFallbackAllocatesLowestFreeValue(t *testing.T) {
	env := newTestClient(t)

	value, err := AllocateLeaseID(context.Background(), env.Client, "service-id", ServiceIDPool.Name, 1, 2, "corr-1")
	if err != nil {
		t.Fatalf("allocate: %v", err)
	}
	if value != 1 {
		t.Fatalf("value = %d, want 1", value)
	}
	var lease coordinationv1.Lease
	if err := env.Client.Get(context.Background(), objectKey(LeaseName("service-id", ServiceIDPool.Name, 1)), &lease); err != nil {
		t.Fatalf("lease not found: %v", err)
	}
	if lease.Labels[LabelAllocationBackend] != BackendLease {
		t.Errorf("allocation-backend label = %q", lease.Labels[LabelAllocationBackend])
	}
	if lease.Labels[LabelAllocationPool] != sanitize(ServiceIDPool.Name) {
		t.Errorf("allocation-pool label = %q", lease.Labels[LabelAllocationPool])
	}
	if lease.Annotations[AnnotationCorrelationID] != "corr-1" {
		t.Errorf("correlation annotation = %q", lease.Annotations[AnnotationCorrelationID])
	}
	if got := lease.Annotations[AnnotationAllocatedID]; got != "1" {
		t.Errorf("allocated-id annotation = %q", got)
	}
	if lease.Spec.HolderIdentity == nil || *lease.Spec.HolderIdentity != "corr-1" {
		t.Errorf("holderIdentity = %v", lease.Spec.HolderIdentity)
	}
}

// Mirrors ...::test_release_by_correlation_deletes_matching_fallback_leases.
func TestReleaseDeletesOnlyMatchingFallbackLeases(t *testing.T) {
	env := newTestClient(t)
	mine := seedLease(t, env, "service-id", ServiceIDPool.Name, 1, "corr-1")
	seedLease(t, env, "rt", "rt-index", 1, "other")

	deleted, err := ReleaseByCorrelationID(context.Background(), env.Client, "corr-1")
	if err != nil {
		t.Fatalf("release: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("deleted = %d, want 1", deleted)
	}
	var check coordinationv1.Lease
	err = env.Client.Get(context.Background(), objectKey(mine.Name), &check)
	if !apierrors.IsNotFound(err) {
		t.Fatalf("expected lease gone (NotFound), got %v", err)
	}
}

func TestLeaseFallbackIsIdempotentForSameCorrelationID(t *testing.T) {
	env := newTestClient(t)
	ctx := context.Background()
	first, err := AllocateLeaseID(ctx, env.Client, "service-id", ServiceIDPool.Name, 1, 5, "corr-1")
	if err != nil {
		t.Fatalf("first: %v", err)
	}
	second, err := AllocateLeaseID(ctx, env.Client, "service-id", ServiceIDPool.Name, 1, 5, "corr-1")
	if err != nil {
		t.Fatalf("same value + same correlation id is a no-op: %v", err)
	}
	if first != second {
		t.Fatalf("got %d then %d", first, second)
	}
	// Exactly one lease per value must exist.
	var leases coordinationv1.LeaseList
	if err := env.Client.List(ctx, &leases, client.InNamespace(Namespace)); err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(leases.Items) != 1 {
		t.Fatalf("leases = %d, want 1", len(leases.Items))
	}
}

func TestLeaseFallbackSkipsValuesHeldByOthers(t *testing.T) {
	env := newTestClient(t)
	seedLease(t, env, "service-id", ServiceIDPool.Name, 1, "corr-other")

	value, err := AllocateLeaseID(context.Background(), env.Client, "service-id", ServiceIDPool.Name, 1, 2, "corr-1")
	if err != nil {
		t.Fatalf("allocate: %v", err)
	}
	if value != 2 {
		t.Fatalf("value = %d, want 2 (1 is taken by another holder)", value)
	}
}

func TestLeaseFallbackExhaustionNamesThePool(t *testing.T) {
	env := newTestClient(t)
	seedLease(t, env, "service-id", ServiceIDPool.Name, 1, "corr-a")
	seedLease(t, env, "service-id", ServiceIDPool.Name, 2, "corr-b")

	_, err := AllocateLeaseID(context.Background(), env.Client, "service-id", ServiceIDPool.Name, 1, 2, "corr-c")
	if !IsExhaustion(err) {
		t.Fatalf("want exhaustion, got %v", err)
	}
	if !containsAll(err.Error(), ServiceIDPool.Name, "1-2") {
		t.Errorf("exhaustion must name pool and range: %v", err)
	}
}

func TestLeaseNameEmbedsTheValue(t *testing.T) {
	got := LeaseName("service-id", ServiceIDPool.Name, 5000)
	want := "agentic-netops-service-id-srv6-service-ids-5000"
	if got != want {
		t.Fatalf("LeaseName = %q, want %q", got, want)
	}
}

func TestLeaseFallbackPreSeededUsedMapIsHonoured(t *testing.T) {
	// A lease carrying the managed labels but a foreign pool label value is
	// invisible to this pool's scan; a lease in this pool without a valid
	// allocated-id annotation must not crash the scan.
	env := newTestClient(t)
	if err := env.Client.Create(context.Background(), &coordinationv1.Lease{
		ObjectMeta: metav1.ObjectMeta{
			Name:      LeaseName("service-id", ServiceIDPool.Name, 1),
			Namespace: Namespace,
			Labels: map[string]string{
				LabelManagedBy:         ManagedBy,
				LabelAllocationBackend: BackendLease,
				LabelAllocationPool:    sanitize(ServiceIDPool.Name),
			},
			Annotations: map[string]string{AnnotationAllocatedID: "not-a-number"},
		},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	value, err := AllocateLeaseID(context.Background(), env.Client, "service-id", ServiceIDPool.Name, 1, 2, "corr-1")
	if err != nil {
		t.Fatalf("allocate: %v", err)
	}
	// The malformed annotation is ignored, and the create collides with the
	// existing name whose correlation annotation is absent — the value is
	// treated as taken and the next one is used.
	if value != 2 {
		t.Fatalf("value = %d, want 2", value)
	}
}

func containsAll(s string, subs ...string) bool {
	for _, sub := range subs {
		if !strings.Contains(s, sub) {
			return false
		}
	}
	return true
}
