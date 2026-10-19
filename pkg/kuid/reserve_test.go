// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"context"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// T606: a named value is reserved under a correlation id; a value already
// held is refused naming pool, value and holder; the same value for the
// same correlation id is a no-op; release by correlation id frees it.
func TestReserveValueLifecycle(t *testing.T) {
	env := newTestClient(t)
	ctx := context.Background()

	// First reservation of 100 under corr-1 creates the value-named claim.
	ref, err := ReserveVLAN(ctx, env.Client, "corr-1", 100)
	if err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if ref.Name != ReserveName(VlanPool, 100) {
		t.Fatalf("claim name not value-derived: %q", ref.Name)
	}
	u, err := getClaim(ctx, env.Client, ref)
	if err != nil {
		t.Fatalf("claim not found: %v", err)
	}
	if u.GetLabels()[LabelCorrelationID] != "corr-1" {
		t.Errorf("correlation label = %q", u.GetLabels()[LabelCorrelationID])
	}
	id, found, err := unstructured.NestedInt64(u.Object, "spec", "id")
	if err != nil || !found || id != 100 {
		t.Errorf("spec.id = %v (found=%v err=%v), want 100", id, found, err)
	}
	index, _, _ := unstructuredString(u.Object["spec"], "index")
	if index != VlanPool.Name {
		t.Errorf("spec.index = %q, want %q", index, VlanPool.Name)
	}

	// Same value, same correlation id: a no-op.
	if _, err := ReserveVLAN(ctx, env.Client, "corr-1", 100); err != nil {
		t.Fatalf("re-reserve by the same holder must be a no-op, got: %v", err)
	}

	// Same value, different correlation id: refused, naming pool, value and
	// holder.
	_, err = ReserveVLAN(ctx, env.Client, "corr-2", 100)
	if err == nil {
		t.Fatal("expected collision for a held value")
	}
	if !IsCollision(err) {
		t.Fatalf("error is not a CollisionError: %v", err)
	}
	for _, want := range []string{VlanPool.Name, "100", "corr-1"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q must name %q", err.Error(), want)
		}
	}

	// Release by correlation id frees the value for the next holder.
	n, err := ReleaseByCorrelationID(ctx, env.Client, "corr-1")
	if err != nil {
		t.Fatalf("release: %v", err)
	}
	if n != 1 {
		t.Fatalf("released %d objects, want 1", n)
	}
	if _, err := ReserveVLAN(ctx, env.Client, "corr-2", 100); err != nil {
		t.Fatalf("reserve after release: %v", err)
	}
}

// The reservation pool joins the release walk (release.go iterates `pools`):
// a reservation made by reserve.go is freed by ReleaseByCorrelationID even
// when the test seeds the claim directly.
func TestReleaseCoversTheReservationPool(t *testing.T) {
	env := newTestClient(t)
	ctx := context.Background()
	if _, err := ReserveValue(ctx, env.Client, VlanPool, "corr-9", 33); err != nil {
		t.Fatalf("seed reservation: %v", err)
	}
	n, err := ReleaseByCorrelationID(ctx, env.Client, "corr-9")
	if err != nil {
		t.Fatalf("release: %v", err)
	}
	if n != 1 {
		t.Fatalf("released %d objects, want 1 (the reservation claim)", n)
	}
	var claims = newListObject(VlanPool)
	if err := env.Client.List(ctx, claims, client.InNamespace(Namespace)); err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(claims.Items) != 0 {
		t.Fatalf("reservation pool still holds %d claim(s)", len(claims.Items))
	}
}

// A reservation never invents a value: a non-positive value and an out of
// range VLAN are refused before any object is created.
func TestReserveRefusesNonsenseValues(t *testing.T) {
	env := newTestClient(t)
	ctx := context.Background()
	if _, err := ReserveValue(ctx, env.Client, VlanPool, "corr-1", 0); err == nil {
		t.Fatal("expected refusal for value 0")
	}
	if _, err := ReserveVLAN(ctx, env.Client, "corr-1", 4095); err == nil {
		t.Fatal("expected refusal for vlan 4095 (outside A8 bounds)")
	}
	var claims = newListObject(VlanPool)
	if err := env.Client.List(ctx, claims, client.InNamespace(Namespace)); err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(claims.Items) != 0 {
		t.Fatalf("refused reserves must not create claims, found %d", len(claims.Items))
	}
}
