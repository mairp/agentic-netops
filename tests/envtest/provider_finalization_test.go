//go:build !integration

package envtest

import (
	"context"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/mairp/agentic-netops/controllers/sonicprovider"
	"github.com/mairp/agentic-netops/pkg/kubenet"
	"github.com/mairp/agentic-netops/pkg/sdc"
)

// TestProviderFinalization simulates deletion flow and ensures ordered finalization evidence.
func TestProviderFinalization(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = kubenet.AddToScheme(scheme)
	_ = sdc.AddToScheme(scheme)
	c := fake.NewClientBuilder().WithScheme(scheme).Build()
	rec := &sonicprovider.Reconciler{Client: c, Scheme: scheme}

	ctx := context.TODO()
	nd := &kubenet.NetworkDevice{ObjectMeta: metav1.ObjectMeta{Name: "leaf01", Namespace: "default"}}
	if err := c.Create(ctx, nd); err != nil {
		t.Fatalf("create nd: %v", err)
	}
	// Add finalizer and a Config owned by ND
	if err := c.Get(ctx, types.NamespacedName{Namespace: nd.Namespace, Name: nd.Name}, nd); err != nil {
		t.Fatalf("get nd: %v", err)
	}
	nd.Finalizers = append(nd.Finalizers, "agentic-netops.dev/finalizer")
	if err := c.Update(ctx, nd); err != nil {
		t.Fatalf("update nd: %v", err)
	}
	cfg := &sdc.Config{ObjectMeta: metav1.ObjectMeta{Name: "nd-leaf01", Namespace: "default"}}
	if err := c.Create(ctx, cfg); err != nil {
		t.Fatalf("create cfg: %v", err)
	}
	// Mark ND as deleting by issuing a Delete (fake client sets deletionTimestamp when finalizers exist)
	if err := c.Delete(ctx, nd); err != nil {
		t.Fatalf("delete nd: %v", err)
	}

	// First reconcile should issue delete; in fake client the Config may be removed immediately
	if _, err := rec.Reconcile(ctx, ctrl.Request{NamespacedName: types.NamespacedName{Namespace: "default", Name: "leaf01"}}); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	// If the Config still exists, delete it to simulate confirmation
	if err := c.Get(ctx, types.NamespacedName{Namespace: "default", Name: "nd-leaf01"}, cfg); err == nil {
		if err := c.Delete(ctx, cfg); err != nil {
			t.Fatalf("delete cfg: %v", err)
		}
	}
	// Second reconcile should record finalized-at and remove finalizer
	if _, err := rec.Reconcile(ctx, ctrl.Request{NamespacedName: types.NamespacedName{Namespace: "default", Name: "leaf01"}}); err != nil {
		t.Fatalf("reconcile2: %v", err)
	}
	if err := c.Get(ctx, types.NamespacedName{Namespace: nd.Namespace, Name: nd.Name}, nd); err == nil {
		if nd.Annotations["agentic-netops.dev/finalized-at"] == "" {
			t.Fatalf("expected finalized-at annotation")
		}
		if contains(nd.Finalizers, "agentic-netops.dev/finalizer") {
			t.Fatalf("expected finalizer removed")
		}
	}
}

func contains(ss []string, s string) bool {
	for _, v := range ss {
		if v == s {
			return true
		}
	}
	return false
}
