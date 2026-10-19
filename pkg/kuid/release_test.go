// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"context"
	"testing"

	coordinationv1 "k8s.io/api/coordination/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Release must cover both served claims and fallback leases, delete only
// the correlation id's objects, and be idempotent.
func TestReleaseByCorrelationIDCoversClaimsAndLeases(t *testing.T) {
	env := newTestClient(t)
	ctx := context.Background()
	ref, err := CreateClientPrefixClaim(ctx, env.Client, "corr-1", "leaf01-eth12")
	if err != nil {
		t.Fatalf("seed claim: %v", err)
	}
	if _, err := CreateServiceIDClaim(ctx, env.Client, "corr-1"); err != nil {
		t.Fatalf("seed service-id claim: %v", err)
	}
	seedLease(t, env, "service-id", ServiceIDPool.Name, 1, "corr-1")
	seedLease(t, env, "service-id", ServiceIDPool.Name, 2, "corr-keep")
	if _, err := CreateServiceIDClaim(ctx, env.Client, "corr-keep"); err != nil {
		t.Fatalf("seed other claim: %v", err)
	}

	deleted, err := ReleaseByCorrelationID(ctx, env.Client, "corr-1")
	if err != nil {
		t.Fatalf("release: %v", err)
	}
	if deleted != 3 {
		t.Fatalf("deleted = %d, want 3 (two claims + one lease)", deleted)
	}
	if _, err := getClaim(ctx, env.Client, ref); !apierrors.IsNotFound(err) {
		t.Errorf("claim should be gone, got %v", err)
	}
	var remaining coordinationv1.LeaseList
	if err := env.Client.List(ctx, &remaining, client.InNamespace(Namespace)); err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(remaining.Items) != 1 {
		t.Fatalf("another holder's lease must survive, got %d leases", len(remaining.Items))
	}
	if remaining.Items[0].Annotations[AnnotationCorrelationID] != "corr-keep" {
		t.Fatalf("wrong lease survived: %s", remaining.Items[0].Name)
	}
}

func TestReleaseIsIdempotent(t *testing.T) {
	env := newTestClient(t)
	ctx := context.Background()
	if _, err := CreateServiceIDClaim(ctx, env.Client, "corr-1"); err != nil {
		t.Fatalf("seed: %v", err)
	}
	seedLease(t, env, "service-id", ServiceIDPool.Name, 1, "corr-1")

	for _, want := range []int{2, 0, 0} {
		deleted, err := ReleaseByCorrelationID(ctx, env.Client, "corr-1")
		if err != nil {
			t.Fatalf("release: %v", err)
		}
		if deleted != want {
			t.Fatalf("deleted = %d, want %d", deleted, want)
		}
	}
}

// Mirrors agents/tests/unit/test_kuid_client.py::test_release_by_correlation_
// no_claims_is_success: releasing nothing is a success.
func TestReleaseNothingIsSuccess(t *testing.T) {
	env := newTestClient(t)
	deleted, err := ReleaseByCorrelationID(context.Background(), env.Client, "corr-absent")
	if err != nil {
		t.Fatalf("release with nothing held must succeed: %v", err)
	}
	if deleted != 0 {
		t.Fatalf("deleted = %d, want 0", deleted)
	}
}
