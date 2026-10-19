// SPDX-License-Identifier: Apache-2.0
//
// Identifier-claim tests, T374/T376 and T610 (allocate.go):
//
//   - T374: the §8.1 profile is claimed under the correlation id — the
//     deployer label when present, else the object UID — and the claimed
//     identifiers are recorded in status.allocations +
//     status.correlationId;
//   - T376: pool exhaustion gives a terminal PoolExhausted naming the pool,
//     and every partial claim is released BEFORE any device write;
//   - T610: a mac-vrf's operator-named VLAN is reserved through pkg/kuid
//     under the service's correlation id, recorded in status.allocations; a
//     value held by another correlation id is a terminal VlanInUse naming
//     the holder, and the claims already made are released.
package srv6service

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"

	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/kuid"
	"github.com/mairp/agentic-netops/pkg/reasons"
	coordinationv1 "k8s.io/api/coordination/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// requireRefusal unwraps an Allocate error into its *Refusal.
func requireRefusal(t *testing.T, err error, reason string) *Refusal {
	t.Helper()
	if err == nil {
		t.Fatalf("Allocate succeeded, want a %s refusal", reason)
	}
	var ref *Refusal
	if !errors.As(err, &ref) {
		t.Fatalf("Allocate error %v is not a *Refusal", err)
	}
	if ref.Reason != reason {
		t.Fatalf("refusal reason = %q (%s), want %q", ref.Reason, ref.Message, reason)
	}
	if !ref.Terminal() {
		t.Errorf("refusal %q must be terminal", ref.Reason)
	}
	return ref
}

// TestAllocateClaimsProfileUnderTheCorrelationID is T374: the served GENID
// claim cannot allocate here (no status ever arrives), so the Lease fallback
// takes over — the documented GENID fallback — and the client /24 claims are
// created under the correlation id. The deployer label, not the object UID,
// is the correlation id when the label is present.
func TestAllocateClaimsProfileUnderTheCorrelationID(t *testing.T) {
	const corrID = "deployer-42"
	svc := testService("alloc-profile", corrID)
	c := newTestClient(t, svc) // empty claim store: the served GENID wait runs out

	_, err := Allocate(context.Background(), c, svc, correlationID(svc), DefaultSiteFacts().Locators)
	if err == nil || !strings.Contains(err.Error(), "client /24 claim for leaf01 not ready") {
		t.Fatalf("Allocate err = %v, want the client /24 claim wait to time out", err)
	}

	// The service-id claims carry the correlation id label.
	var genid unstructured.Unstructured
	genid.SetGroupVersionKind(schema.GroupVersionKind{
		Group: kuid.ServiceIDPool.Group, Version: kuid.ServiceIDPool.Version, Kind: kuid.ServiceIDPool.Kind})
	if err := c.Get(context.Background(), client.ObjectKey{
		Namespace: kuid.Namespace, Name: kuid.ClaimName(kuid.ServiceIDPool, corrID)}, &genid); err != nil {
		t.Fatalf("service-id claim not created: %v", err)
	}
	if genid.GetLabels()[kuid.LabelCorrelationID] != corrID {
		t.Errorf("service-id claim label = %q, want %q", genid.GetLabels()[kuid.LabelCorrelationID], corrID)
	}
	// The Lease fallback allocated the first free id, 1 (range 1..999).
	var lease coordinationv1.Lease
	if err := c.Get(context.Background(), client.ObjectKey{
		Namespace: kuid.Namespace, Name: kuid.LeaseName("service", kuid.ServiceIDPool.Name, 1)}, &lease); err != nil {
		t.Fatalf("fallback lease not created: %v", err)
	}
	if lease.Annotations[kuid.AnnotationAllocatedID] != "1" ||
		lease.Annotations[kuid.AnnotationCorrelationID] != corrID {
		t.Errorf("lease holds id %q for %q, want 1 for %q",
			lease.Annotations[kuid.AnnotationAllocatedID], lease.Annotations[kuid.AnnotationCorrelationID], corrID)
	}
	// One client /24 claim per attachment, each labelled. The claim loop
	// aborts at the first wait timeout, so only the (sorted) first
	// attachment's claim exists at this point.
	var ip unstructured.Unstructured
	ip.SetGroupVersionKind(schema.GroupVersionKind{
		Group: kuid.ClientV4Pool.Group, Version: kuid.ClientV4Pool.Version, Kind: kuid.ClientV4Pool.Kind})
	first := svc.Spec.Attachments[0]
	if first.Node != "leaf01" {
		first = svc.Spec.Attachments[1]
	}
	if err := c.Get(context.Background(), client.ObjectKey{
		Namespace: kuid.Namespace,
		Name:      kuid.ClaimName(kuid.ClientV4Pool, corrID, first.Node+"-"+first.Port)}, &ip); err != nil {
		t.Fatalf("client /24 claim for %s not created: %v", first.Node, err)
	}
	if ip.GetLabels()[kuid.LabelCorrelationID] != corrID {
		t.Errorf("client /24 claim label = %q, want %q", ip.GetLabels()[kuid.LabelCorrelationID], corrID)
	}

	// The claimed identifiers are recorded as the §2 status allocations with
	// the correlation id (here the full allocation was pre-served).
	full := &Allocation{Allocations: &agenticnetopsv1alpha1.Allocations{
		ServiceID:      7,
		VRF:            "Vrf7",
		ClientPrefixes: map[string]string{"leaf01": "192.168.35.0/24", "leaf02": "192.168.36.0/24"},
	}}
	st := &agenticnetopsv1alpha1.SRv6ServiceStatus{}
	setReadyOutcome(st, svc.Generation, nil, nil, correlationID(svc), "", full.Allocations)
	if st.CorrelationID != corrID {
		t.Errorf("status.correlationId = %q, want the deployer label %q", st.CorrelationID, corrID)
	}
	if st.Allocations == nil || st.Allocations.ServiceID != 7 || st.Allocations.VRF != "Vrf7" ||
		st.Allocations.ClientPrefixes["leaf02"] != "192.168.36.0/24" {
		t.Errorf("status.allocations = %+v, want the claimed profile", st.Allocations)
	}

	// The UID fallback: without the label the object UID is the correlation
	// id, so every claim is still traceable to its service.
	unlabelled := testService("alloc-uid", "")
	if got := correlationID(unlabelled); got != string(unlabelled.UID) {
		t.Errorf("correlationID = %q, want the object UID %q", got, unlabelled.UID)
	}
}

// fillServiceIDRange pre-creates the fallback Leases 1..999 for another
// holder, exhausting the service-id range.
func fillServiceIDRange(t *testing.T, c client.Client, holder string) {
	t.Helper()
	for value := 1; value <= 999; value++ {
		lease := &coordinationv1.Lease{
			ObjectMeta: metav1.ObjectMeta{
				Name:      kuid.LeaseName("service", kuid.ServiceIDPool.Name, value),
				Namespace: kuid.Namespace,
				Labels: map[string]string{
					kuid.LabelManagedBy:         kuid.ManagedBy,
					kuid.LabelAllocationBackend: kuid.BackendLease,
					kuid.LabelAllocationPool:    kuid.ServiceIDPool.Name,
					kuid.LabelAllocationKind:    "service",
				},
				Annotations: map[string]string{
					kuid.AnnotationCorrelationID: holder,
					kuid.AnnotationAllocatedID:   strconv.Itoa(value),
				},
			},
		}
		if err := c.Create(context.Background(), lease); err != nil {
			t.Fatalf("pre-create lease %d: %v", value, err)
		}
	}
}

// TestPoolExhaustionReleasesPartialClaims is T376: with the whole fallback
// range taken by other holders, the refusal is the terminal PoolExhausted
// naming the pool — and the partial claims this service already made are
// released. Reconcile level, so "before any device write" is witnessed by
// the executor having seen nothing. The served claims are NOT pre-created
// here: the served GENID path would answer instantly and the fallback (the
// exhausted pool) would never run.
func TestPoolExhaustionReleasesPartialClaims(t *testing.T) {
	const corrID = "exhausted-1"
	const name = "exhausted-1"
	svc := testService(name, corrID)
	c := newTestClient(t, svc)
	fillServiceIDRange(t, c, "someone-else")

	ex := &recordingExecutor{}
	got := convergeService(t, c, ex, goodPins(), name)
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Reason != reasons.ReasonPoolExhausted {
		t.Fatalf("Ready reason = %+v, want %s", cond, reasons.ReasonPoolExhausted)
	}
	for _, want := range []string{kuid.ServiceIDPool.Name, "exhaust"} {
		if !strings.Contains(cond.Message, want) {
			t.Errorf("message %q must name %q", cond.Message, want)
		}
	}
	// The partial claim this service made (the served service-id claim) is
	// released; the other holders' fallback leases are not.
	if n := countClaims(t, c); n != 0 {
		t.Errorf("%d claims left, want every partial claim released", n)
	}
	var leases coordinationv1.LeaseList
	if err := c.List(context.Background(), &leases, client.InNamespace(kuid.Namespace)); err != nil {
		t.Fatalf("list leases: %v", err)
	}
	held := 0
	for i := range leases.Items {
		if leases.Items[i].Annotations[kuid.AnnotationCorrelationID] == corrID {
			held++
		}
	}
	if held != 0 {
		t.Errorf("%d fallback leases still carry this correlation id; the release must free them", held)
	}
	if got.Status.Allocations != nil {
		t.Error("status.allocations recorded for an exhausted pool")
	}
	assertNoDeviceWrites(t, ex)
}

// TestVLANReservedUnderCorrelationID is T610's recorded half: a mac-vrf's
// operator-named VLAN is reserved as a value-named kuid claim under the
// service's correlation id and recorded in the status allocations.
func TestVLANReservedUnderCorrelationID(t *testing.T) {
	const corrID = "mac-svc-1"
	svc := testService("mac-vlan", corrID)
	svc.Spec.Construct = agenticnetopsv1alpha1.ConstructMACVRF
	vlan := int64(130)
	svc.Spec.VLAN = &vlan
	c := newTestClient(t, svc)
	testClaims(t, c, corrID) // service id + client /24s pre-served: instant claims

	alloc, err := Allocate(context.Background(), c, svc, correlationID(svc), DefaultSiteFacts().Locators)
	if err != nil {
		t.Fatalf("Allocate: %v", err)
	}
	if alloc.Allocations.VLAN == nil || *alloc.Allocations.VLAN != vlan {
		t.Fatalf("allocations.vlan = %v, want %d", alloc.Allocations.VLAN, vlan)
	}
	var res unstructured.Unstructured
	res.SetGroupVersionKind(schema.GroupVersionKind{
		Group: kuid.VlanPool.Group, Version: kuid.VlanPool.Version, Kind: kuid.VlanPool.Kind})
	if err := c.Get(context.Background(), client.ObjectKey{
		Namespace: kuid.Namespace, Name: kuid.ReserveName(kuid.VlanPool, vlan)}, &res); err != nil {
		t.Fatalf("vlan reservation not created: %v", err)
	}
	if res.GetLabels()[kuid.LabelCorrelationID] != corrID {
		t.Errorf("reservation label = %q, want %q", res.GetLabels()[kuid.LabelCorrelationID], corrID)
	}
	if id, _, _ := unstructured.NestedInt64(res.Object, "spec", "id"); id != vlan {
		t.Errorf("reservation spec.id = %d, want the operator-named %d", id, vlan)
	}
	// The reservation is recorded in the §2 status allocations.
	st := &agenticnetopsv1alpha1.SRv6ServiceStatus{}
	setReadyOutcome(st, 1, nil, nil, corrID, "", alloc.Allocations)
	if st.Allocations == nil || st.Allocations.VLAN == nil || *st.Allocations.VLAN != vlan {
		t.Errorf("status.allocations.vlan = %+v, want %d", st.Allocations, vlan)
	}
	// Reserving OUR value again is a no-op, not a collision.
	if _, err := kuid.ReserveVLAN(context.Background(), c, corrID, vlan); err != nil {
		t.Errorf("re-reserving our own vlan: %v", err)
	}
}

// TestVLANHeldByAnotherHolderRefusesAndReleases is T610's refusal half: a
// vlan value already reserved by another correlation id is a terminal
// VlanInUse naming the holder, and the claims this service already made are
// released — still before any device write.
func TestVLANHeldByAnotherHolderRefusesAndReleases(t *testing.T) {
	const corrID = "mac-svc-2"
	const holder = "mac-svc-1"
	svc := testService("mac-vlan-taken", corrID)
	svc.Spec.Construct = agenticnetopsv1alpha1.ConstructMACVRF
	vlan := int64(130)
	svc.Spec.VLAN = &vlan
	c := newTestClient(t, svc)
	testClaims(t, c, corrID) // service id + client /24s: instant claims
	// The value is held by another service's reservation.
	if err := c.Create(context.Background(), claimObject(kuid.VlanPool,
		kuid.ReserveName(kuid.VlanPool, vlan), holder, nil)); err != nil {
		t.Fatalf("pre-create reservation: %v", err)
	}

	_, err := Allocate(context.Background(), c, svc, correlationID(svc), DefaultSiteFacts().Locators)
	ref := requireRefusal(t, err, reasons.ReasonVlanInUse)
	for _, want := range []string{"130", "another holder", holder} {
		if !strings.Contains(ref.Message, want) {
			t.Errorf("message %q must name %q", ref.Message, want)
		}
	}
	// The partial claims (service id + two client /24s) are released; the
	// other holder's reservation is not.
	if n := countClaims(t, c); n != 1 {
		t.Errorf("%d claims left, want only the other holder's vlan reservation", n)
	}
	var res unstructured.Unstructured
	res.SetGroupVersionKind(schema.GroupVersionKind{
		Group: kuid.VlanPool.Group, Version: kuid.VlanPool.Version, Kind: kuid.VlanPool.Kind})
	if err := c.Get(context.Background(), client.ObjectKey{
		Namespace: kuid.Namespace, Name: kuid.ReserveName(kuid.VlanPool, vlan)}, &res); err != nil {
		t.Fatalf("other holder's reservation was deleted: %v", err)
	}
	if res.GetLabels()[kuid.LabelCorrelationID] != holder {
		t.Errorf("reservation holder = %q, want %q", res.GetLabels()[kuid.LabelCorrelationID], holder)
	}
}
