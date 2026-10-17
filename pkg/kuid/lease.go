// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"context"
	"fmt"
	"strconv"

	coordinationv1 "k8s.io/api/coordination/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Lease fallback labels/annotations, mirroring agents/provisioning/
// allocator/kuid.py (LEASE_LABELS and friends).
const (
	LabelAllocationBackend = "agentic-netops.io/allocation-backend"
	LabelAllocationPool    = "agentic-netops.io/allocation-pool"
	LabelAllocationKind    = "agentic-netops.io/allocation-kind"

	// BackendLease is the value of LabelAllocationBackend on fallback leases.
	BackendLease = "lease"
	// AnnotationCorrelationID records the holder of a fallback lease.
	AnnotationCorrelationID = LabelCorrelationID
	// AnnotationAllocatedID records the integer value a fallback lease holds.
	AnnotationAllocatedID = "agentic-netops.io/allocated-id"

	// leaseDurationSeconds is effectively permanent; kuid.py uses the same
	// ten-year value because a held id lives exactly as long as its service.
	leaseDurationSeconds = 315360000
)

// LeaseName mirrors kuid.py's _fallback_lease_name: the lease name embeds
// the integer value, so creation is the atomic allocation step.
func LeaseName(kind, pool string, value int) string {
	return sanitize("agentic-netops-"+kind+"-"+pool) + "-" + strconv.Itoa(value)
}

// AllocateLeaseID is the Kubernetes-Lease fallback for a broken kuid pool:
// the pinned kuid-server's GENID family fails at runtime (tier finding,
// research.md Decision 11), so the service-id range [first,last] is
// allocated by atomically creating a coordination.k8s.io Lease named after
// the value. Creation success means allocation; a name collision means the
// value is taken — unless the existing lease carries the same correlation
// id, in which case it is a no-op returning that value. When every value is
// taken the error is an ExhaustionError naming the pool.
func AllocateLeaseID(ctx context.Context, c client.Client, kind, pool string, first, last int, correlationID string) (int, error) {
	var leases coordinationv1.LeaseList
	if err := c.List(ctx, &leases,
		client.InNamespace(Namespace),
		client.MatchingLabels{
			LabelManagedBy:         ManagedBy,
			LabelAllocationBackend: BackendLease,
			LabelAllocationPool:    sanitize(pool),
		}); err != nil {
		return 0, classify(pool, err)
	}
	used := map[int]bool{}
	for i := range leases.Items {
		item := leases.Items[i]
		// Same kind + same pool + same correlation id: this service already
		// holds a value here — a no-op, not a new allocation.
		if item.Labels[LabelAllocationKind] == sanitize(kind) &&
			item.Annotations[AnnotationCorrelationID] == correlationID {
			if v, err := strconv.Atoi(item.Annotations[AnnotationAllocatedID]); err == nil {
				return v, nil
			}
		}
		raw, ok := item.Annotations[AnnotationAllocatedID]
		if !ok {
			continue
		}
		if v, err := strconv.Atoi(raw); err == nil {
			used[v] = true
		}
	}
	for value := first; value <= last; value++ {
		if used[value] {
			continue
		}
		lease := newLease(kind, pool, value, correlationID)
		err := c.Create(ctx, lease)
		switch {
		case err == nil:
			return value, nil
		case apierrors.IsAlreadyExists(err):
			// Name taken: same correlation id means we already hold it
			// (no-op); anyone else means the value is spent.
			var existing coordinationv1.Lease
			if getErr := c.Get(ctx, client.ObjectKey{Namespace: Namespace, Name: lease.Name}, &existing); getErr == nil {
				if existing.Annotations[AnnotationCorrelationID] == correlationID {
					return value, nil
				}
			}
			continue
		default:
			return 0, classify(pool, err)
		}
	}
	return 0, &ExhaustionError{
		Pool:   pool,
		Detail: fmt.Sprintf("no available %s ids (%d-%d)", kind, first, last),
	}
}

// newLease builds the fallback Lease body for one integer value, mirroring
// kuid.py's _fallback_lease_body.
func newLease(kind, pool string, value int, correlationID string) *coordinationv1.Lease {
	holder := correlationID
	if len(holder) > 63 {
		holder = holder[:63]
	}
	if holder == "" {
		holder = ManagedBy
	}
	return &coordinationv1.Lease{
		ObjectMeta: metav1.ObjectMeta{
			Name:      LeaseName(kind, pool, value),
			Namespace: Namespace,
			Labels: map[string]string{
				LabelManagedBy:         ManagedBy,
				LabelAllocationBackend: BackendLease,
				LabelAllocationKind:    sanitize(kind),
				LabelAllocationPool:    sanitize(pool),
			},
			Annotations: map[string]string{
				AnnotationCorrelationID: correlationID,
				AnnotationAllocatedID:   strconv.Itoa(value),
			},
		},
		Spec: coordinationv1.LeaseSpec{
			HolderIdentity:       &holder,
			LeaseDurationSeconds: int32Ptr(leaseDurationSeconds),
		},
	}
}

func int32Ptr(v int) *int32 {
	out := int32(v)
	return &out
}
