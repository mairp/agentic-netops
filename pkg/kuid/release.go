// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"context"

	coordinationv1 "k8s.io/api/coordination/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// ReleaseByCorrelationID deletes every claim and every fallback Lease
// carrying the given correlation id (label on claims, annotation on
// leases) in kuid-system. It is idempotent: releasing nothing is a success
// and returns 0. It returns the number of objects deleted.
func ReleaseByCorrelationID(ctx context.Context, c client.Client, correlationID string) (int, error) {
	deleted := 0
	for _, pool := range pools {
		list := newListObject(pool)
		if err := c.List(ctx, list,
			client.InNamespace(Namespace),
			client.MatchingLabels{LabelCorrelationID: correlationID}); err != nil {
			return deleted, err
		}
		for i := range list.Items {
			if err := c.Delete(ctx, &list.Items[i]); err != nil && !apierrors.IsNotFound(err) {
				return deleted, classify(pool.Name, err)
			}
			deleted++
		}
	}
	n, err := releaseFallbackLeases(ctx, c, correlationID)
	deleted += n
	return deleted, err
}

// releaseFallbackLeases deletes every fallback Lease whose correlation-id
// annotation matches. Mirror of kuid.py's _release_fallback_leases.
func releaseFallbackLeases(ctx context.Context, c client.Client, correlationID string) (int, error) {
	var leases coordinationv1.LeaseList
	if err := c.List(ctx, &leases,
		client.InNamespace(Namespace),
		client.MatchingLabels{LabelManagedBy: ManagedBy, LabelAllocationBackend: BackendLease}); err != nil {
		return 0, err
	}
	deleted := 0
	for i := range leases.Items {
		lease := &leases.Items[i]
		if lease.Annotations[AnnotationCorrelationID] != correlationID {
			continue
		}
		if err := c.Delete(ctx, lease); err != nil && !apierrors.IsNotFound(err) {
			return deleted, classify(lease.Labels[LabelAllocationPool], err)
		}
		deleted++
	}
	return deleted, nil
}
