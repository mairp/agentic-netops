// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"errors"
	"strings"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestTypedErrorsNameThePool(t *testing.T) {
	col := &CollisionError{Pool: ServiceIDPool.Name, Detail: "value taken"}
	if !strings.Contains(col.Error(), ServiceIDPool.Name) {
		t.Errorf("collision must name the pool: %v", col)
	}
	exh := &ExhaustionError{Pool: ClientV4Pool.Name, Detail: "no /24 left"}
	if !strings.Contains(exh.Error(), ClientV4Pool.Name) {
		t.Errorf("exhaustion must name the pool: %v", exh)
	}
	if !IsCollision(col) || IsExhaustion(col) {
		t.Error("collision misclassified")
	}
	if !IsExhaustion(exh) || IsCollision(exh) {
		t.Error("exhaustion misclassified")
	}
	if IsCollision(nil) || IsExhaustion(nil) {
		t.Error("nil must classify as neither")
	}
}

func TestClassifyMapsAlreadyExistsToCollision(t *testing.T) {
	already := apierrors.NewAlreadyExists(
		schema.GroupResource{Group: ServiceIDPool.Group, Resource: ServiceIDPool.Plural},
		"some-claim")
	err := classify(ServiceIDPool.Name, already)
	if !IsCollision(err) {
		t.Fatalf("want collision, got %v", err)
	}
	if !strings.Contains(err.Error(), ServiceIDPool.Name) {
		t.Errorf("must name the pool: %v", err)
	}
}

func TestClassifyMapsWrappedInternalExistsToCollision(t *testing.T) {
	// The pinned kuid-server answers a duplicate claim create with
	// reason=InternalError and the exists phrase glued (no space):
	// `Internal error occurred: Internal error occurred: AlreadyExists`
	// (measured live 2026-10-16 on ipam.be.kuid.dev IPClaim). The Status
	// reason is not AlreadyExists, so only the message can carry it.
	wrapped := apierrors.NewInternalError(
		errors.New("Internal error occurred: AlreadyExists"))
	err := classify(ClientV4Pool.Name, wrapped)
	if !IsCollision(err) {
		t.Fatalf("want collision for %q, got %v", wrapped.Error(), err)
	}
	if !strings.Contains(err.Error(), ClientV4Pool.Name) {
		t.Errorf("must name the pool: %v", err)
	}
}

func TestClassifyMapsExhaustionBodies(t *testing.T) {
	for _, body := range []string{
		"admission webhook denied: pool srv6-service-ids exhausted",
		"no available ids in srv6-service-ids",
	} {
		err := classify(ServiceIDPool.Name, apierrors.NewBadRequest(body))
		if !IsExhaustion(err) {
			t.Errorf("%q: want exhaustion, got %v", body, err)
		}
		if !strings.Contains(err.Error(), ServiceIDPool.Name) {
			t.Errorf("%q: must name the pool: %v", body, err)
		}
	}
}

func TestClassifyPassesUnknownErrorsThrough(t *testing.T) {
	other := apierrors.NewBadRequest("invalid spec")
	err := classify(ServiceIDPool.Name, other)
	if IsCollision(err) || IsExhaustion(err) {
		t.Fatalf("unknown error reclassified: %v", err)
	}
	if err.Error() != other.Error() {
		t.Fatalf("pass-through changed the error: %v", err)
	}
	if classify(ServiceIDPool.Name, nil) != nil {
		t.Fatal("nil must stay nil")
	}
}
