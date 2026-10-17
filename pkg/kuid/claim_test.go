// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"context"
	"errors"
	"strings"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func newTestClient(t *testing.T) *testEnv {
	t.Helper()
	return &testEnv{Client: fake.NewClientBuilder().WithScheme(newScheme(t)).Build()}
}

func TestCreateServiceIDClaimStampsCorrelationBeforeWait(t *testing.T) {
	env := newTestClient(t)
	ref, err := CreateServiceIDClaim(context.Background(), env.Client, "corr-1")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if ref.Name != ClaimName(ServiceIDPool, "corr-1") {
		t.Fatalf("claim name not deterministic: %q", ref.Name)
	}
	u, err := getClaim(context.Background(), env.Client, ref)
	if err != nil {
		t.Fatalf("get claim: %v", err)
	}
	labels := u.GetLabels()
	if labels[LabelCorrelationID] != "corr-1" {
		t.Errorf("correlation label = %q", labels[LabelCorrelationID])
	}
	if labels[LabelManagedBy] != ManagedBy {
		t.Errorf("managed-by label = %q", labels[LabelManagedBy])
	}
	if u.GetNamespace() != Namespace {
		t.Errorf("namespace = %q", u.GetNamespace())
	}
	index, _, _ := unstructuredString(u.Object["spec"], "index")
	if index != ServiceIDPool.Name {
		t.Errorf("spec.index = %q, want %q", index, ServiceIDPool.Name)
	}
}

func unstructuredString(obj any, key string) (string, bool, error) {
	m, ok := obj.(map[string]any)
	if !ok {
		return "", false, nil
	}
	v, _ := m[key].(string)
	return v, v != "", nil
}

func TestCreateClientPrefixClaimAsksFor24(t *testing.T) {
	env := newTestClient(t)
	ref, err := CreateClientPrefixClaim(context.Background(), env.Client, "corr-1", "leaf01-eth12")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	u, err := getClaim(context.Background(), env.Client, ref)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if u.GetLabels()[LabelCorrelationID] != "corr-1" {
		t.Fatalf("correlation id must be stamped before any wait")
	}
	spec, _ := u.Object["spec"].(map[string]any)
	if spec["index"] != ClientV4Pool.Name {
		t.Errorf("spec.index = %v", spec["index"])
	}
	length, ok := spec["prefixLength"].(int64)
	if !ok || length != 24 {
		t.Errorf("spec.prefixLength = %v, want 24", spec["prefixLength"])
	}
	// The served IPClaim validation rejects prefixLength without createPrefix
	// ("dynamicIPRange cannot have a prefixLength", live 2026-10-16).
	if spec["createPrefix"] != true {
		t.Errorf("spec.createPrefix = %v, want true (required for a /24 carve)", spec["createPrefix"])
	}
}

func TestCreateClaimIsIdempotentForSameCorrelationID(t *testing.T) {
	env := newTestClient(t)
	ctx := context.Background()
	first, err := CreateServiceIDClaim(ctx, env.Client, "corr-1")
	if err != nil {
		t.Fatalf("first create: %v", err)
	}
	second, err := CreateServiceIDClaim(ctx, env.Client, "corr-1")
	if err != nil {
		t.Fatalf("second create (same correlation id) must be a no-op: %v", err)
	}
	if first.Name != second.Name {
		t.Fatalf("names differ: %q vs %q", first.Name, second.Name)
	}
}

func TestCreateClaimCollisionNamesThePool(t *testing.T) {
	env := newTestClient(t)
	ctx := context.Background()
	// Someone else already created the object this correlation id would
	// deterministically land on, holding it under a different correlation
	// id: the value is taken.
	held := newClaimObject(ServiceIDPool)
	held.SetNamespace(Namespace)
	held.SetName(ClaimName(ServiceIDPool, "corr-1"))
	held.SetLabels(map[string]string{LabelCorrelationID: "corr-other", LabelManagedBy: ManagedBy})
	held.Object["spec"] = claimSpec(ServiceIDPool)
	if err := env.Client.Create(ctx, held); err != nil {
		t.Fatalf("seed held claim: %v", err)
	}

	_, err := CreateServiceIDClaim(ctx, env.Client, "corr-1")
	if !IsCollision(err) {
		t.Fatalf("want collision, got %v", err)
	}
	if !strings.Contains(err.Error(), ServiceIDPool.Name) {
		t.Errorf("collision error must name the pool: %v", err)
	}
	if !strings.Contains(err.Error(), "corr-other") {
		t.Errorf("collision error should name the holder: %v", err)
	}
}

func TestCreateClaimTreatsWrappedExistsAsNoOp(t *testing.T) {
	// The pinned kuid-server answers a duplicate IPClaim create with
	// reason=InternalError and `Internal error occurred: AlreadyExists`
	// (measured live 2026-10-16); apierrors.IsAlreadyExists is false for
	// it, yet the object exists under OUR correlation id — the documented
	// no-op. Before the loose exists check this raw error escaped
	// classification and the reconcile loop requeued forever.
	ctx := context.Background()
	ref, err := CreateClientPrefixClaim(ctx, newTestClient(t), "corr-1", "leaf01-wan1")
	if err != nil {
		t.Fatalf("seed create: %v", err)
	}

	got, err := CreateClientPrefixClaim(ctx, existsInterceptorClient(t, newTestClient(t).Client), "corr-1", "leaf01-wan1")
	if err != nil {
		t.Fatalf("duplicate create under our correlation id must be a no-op, got %v", err)
	}
	if got.Name != ref.Name {
		t.Fatalf("name drifted: %q vs %q", got.Name, ref.Name)
	}
}

func TestCreateClaimWrappedExistsOtherHolderStillCollides(t *testing.T) {
	// The loose exists check must not soften a REAL collision: the object
	// exists and carries a different correlation id.
	ctx := context.Background()
	name := ClaimName(ClientV4Pool, "corr-1", "leaf01-wan1")
	env := newTestClient(t)
	held := newClaimObject(ClientV4Pool)
	held.SetNamespace(Namespace)
	held.SetName(name)
	held.SetLabels(map[string]string{LabelCorrelationID: "corr-other", LabelManagedBy: ManagedBy})
	held.Object["spec"] = claimSpec(ClientV4Pool)
	if err := env.Create(ctx, held); err != nil {
		t.Fatalf("seed held claim: %v", err)
	}

	_, err := CreateClientPrefixClaim(ctx, existsInterceptorClient(t, env.Client), "corr-1", "leaf01-wan1")
	if !IsCollision(err) {
		t.Fatalf("want collision, got %v", err)
	}
	if !strings.Contains(err.Error(), "corr-other") {
		t.Errorf("collision should name the holder: %v", err)
	}
}

// existsInterceptorClient wraps inner so Create always fails with the
// pinned kuid-server's wrapped exists answer (reason InternalError, message
// `Internal error occurred: AlreadyExists`) while Get still reaches inner —
// the create-reported state and the stored state are observed separately,
// exactly as the live server presents them.
func existsInterceptorClient(t *testing.T, inner client.Client) client.Client {
	t.Helper()
	return createFailingClient{Client: inner}
}

// createFailingClient overrides Create only; every other verb is inherited.
type createFailingClient struct {
	client.Client
}

func (c createFailingClient) Create(_ context.Context, _ client.Object, _ ...client.CreateOption) error {
	return apierrors.NewInternalError(errors.New("Internal error occurred: AlreadyExists"))
}

func TestDistinctServicesGetDistinctClaims(t *testing.T) {
	env := newTestClient(t)
	ctx := context.Background()
	a, err := CreateServiceIDClaim(ctx, env.Client, "corr-1")
	if err != nil {
		t.Fatalf("corr-1: %v", err)
	}
	b, err := CreateServiceIDClaim(ctx, env.Client, "corr-2")
	if err != nil {
		t.Fatalf("corr-2: %v", err)
	}
	if a.Name == b.Name {
		t.Fatalf("two services share a claim name %q", a.Name)
	}
}
