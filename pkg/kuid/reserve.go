// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"context"
	"fmt"
	"strconv"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// VlanPool is the tier's fabric-vlan index (vlan.be.kuid.dev/v1alpha1,
// deploy/kuid/indices.yaml): the index data-model.md §4 says a mac-vrf's
// operator-named VLAN is reserved from. The served VLANClaimSpec carries an
// optional `id` field ("ID defines the id of the resource", verified with
// `kubectl explain vlanclaims.vlan.be.kuid.dev.spec`), so the reservation is
// a claim that REQUESTS the value; the value-named Lease fallback of
// lease.go exists for pools whose served API cannot.
var VlanPool = Pool{
	Name:    "fabric-vlan",
	Group:   "vlan.be.kuid.dev",
	Version: "v1alpha1",
	Kind:    "VLANClaim",
	Plural:  "vlanclaims",
}

func init() {
	// The reservation pool joins the release walk: a claim this package can
	// create is a claim ReleaseByCorrelationID must delete.
	pools = append(pools, VlanPool)
}

// ReserveName is the value-named claim name of one reservation: the claim
// object itself is the reservation, so a second service's create on the
// same name is the collision the served API would also raise for a
// duplicate id inside the index.
func ReserveName(pool Pool, value int64) string {
	return sanitize(pool.Name + "-reserve-value-" + strconv.FormatInt(value, 10))
}

// ReserveValue reserves the named value in pool under the correlation id.
//
//   - The claim requests the value in its spec (`id`, the served API accepts
//     one) and carries the correlation id label, so ReleaseByCorrelationID
//     frees it.
//   - A value already held is refused with a CollisionError naming the pool,
//     the value and the holder's correlation id.
//   - Reserving the same value again for the same correlation id is a
//     no-op.
//
// No allocation value is invented here: the caller names the value, exactly
// like the operator names the VLAN of a mac-vrf (data-model.md §4).
func ReserveValue(ctx context.Context, c client.Client, pool Pool, correlationID string, value int64) (ClaimRef, error) {
	if value <= 0 {
		return ClaimRef{}, fmt.Errorf("reserve: value must be positive, got %d", value)
	}
	if correlationID == "" {
		return ClaimRef{}, fmt.Errorf("reserve: correlation id must not be empty")
	}
	ref := ClaimRef{Pool: pool, Name: ReserveName(pool, value)}

	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(schema.GroupVersionKind{
		Group: pool.Group, Version: pool.Version, Kind: pool.Kind,
	})
	u.SetNamespace(Namespace)
	u.SetName(ref.Name)
	u.SetLabels(map[string]string{
		LabelCorrelationID: correlationID,
		LabelManagedBy:     ManagedBy,
	})
	u.Object["spec"] = map[string]any{"index": pool.Name, "id": value}

	if err := c.Create(ctx, u); err != nil {
		if !apierrors.IsAlreadyExists(err) {
			return ref, classify(pool.Name, err)
		}
		// The value-named claim exists: a no-op only when the holder is the
		// same correlation id; otherwise the value is taken and the refusal
		// names pool, value and holder.
		existing, getErr := getClaim(ctx, c, ref)
		if getErr != nil {
			return ref, classify(pool.Name, getErr)
		}
		holder := existing.GetLabels()[LabelCorrelationID]
		if holder == correlationID {
			return ref, nil
		}
		return ref, &CollisionError{
			Pool:   pool.Name,
			Detail: fmt.Sprintf("value %d of pool %s already held by correlation id %q", value, pool.Name, holder),
		}
	}
	return ref, nil
}

// ReserveVLAN reserves the operator-named VLAN of a mac-vrf in the tier's
// fabric-vlan index (data-model.md §4). The 1..4094 bound mirrors admission
// rule A8; whether the value is free inside the index is the served API's
// and the reservation's own value-named claim to decide.
func ReserveVLAN(ctx context.Context, c client.Client, correlationID string, vlan int64) (ClaimRef, error) {
	if vlan < 1 || vlan > 4094 {
		return ClaimRef{}, fmt.Errorf("reserve: vlan %d outside 1..4094", vlan)
	}
	return ReserveValue(ctx, c, VlanPool, correlationID, vlan)
}
