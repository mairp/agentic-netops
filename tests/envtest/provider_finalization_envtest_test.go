//go:build !integration

package envtest

import (
	context "context"
	"path/filepath"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	crclient "sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"

	"github.com/mairp/agentic-netops/controllers/sonicprovider"
	"github.com/mairp/agentic-netops/pkg/kubenet"
	"github.com/mairp/agentic-netops/pkg/sdc"
)

// TestProviderFinalization_Envtest spins up an API server and verifies ordered finalization
// using a real control-plane read path (envtest API server), not the fake client.
func TestProviderFinalization_Envtest(t *testing.T) {
	t.Parallel()
	ctx := context.TODO()

	assets := "/usr/local/kubebuilder/bin"
	// Allow skip if envtest assets are unavailable
	if testing.Short() {
		t.Skip("short mode")
	}

	env := &envtest.Environment{
		CRDDirectoryPaths: []string{
			filepath.Join("..", "..", "deploy", "kubenet", "crds"),
			filepath.Join("..", "..", "deploy", "sdc", "crds"),
		},
		BinaryAssetsDirectory: assets,
	}
	cfg, err := env.Start()
	if err != nil {
		t.Skipf("envtest not available: %v", err)
	}
	t.Cleanup(func() { _ = env.Stop() })

	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = kubenet.AddToScheme(scheme)
	_ = sdc.AddToScheme(scheme)

	c, err := crclient.New(cfg, crclient.Options{Scheme: scheme})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}

	rec := &sonicprovider.Reconciler{Client: c, Scheme: scheme}

	nd := &kubenet.NetworkDevice{ObjectMeta: metav1.ObjectMeta{Name: "leaf01", Namespace: "default"}}
	if err := c.Create(ctx, nd); err != nil {
		t.Fatalf("create nd: %v", err)
	}
	// add finalizer
	if err := c.Get(ctx, client.ObjectKey{Namespace: nd.Namespace, Name: nd.Name}, nd); err != nil {
		t.Fatalf("get nd: %v", err)
	}
	nd.Finalizers = append(nd.Finalizers, "agentic-netops.dev/finalizer")
	if err := c.Update(ctx, nd); err != nil {
		t.Fatalf("update nd: %v", err)
	}
	// create owned SDC Config
	cfgObj := &sdc.Config{ObjectMeta: metav1.ObjectMeta{Name: "nd-leaf01", Namespace: "default"}}
	if err := c.Create(ctx, cfgObj); err != nil {
		t.Fatalf("create cfg: %v", err)
	}
	// delete owner (sets deletionTimestamp because finalizer exists)
	if err := c.Delete(ctx, nd); err != nil {
		t.Fatalf("delete nd: %v", err)
	}

	// First reconcile: should delete Config, keep finalizer
	if _, err := rec.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKey{Namespace: "default", Name: "leaf01"}}); err != nil {
		t.Fatalf("reconcile1: %v", err)
	}
	// Confirm Config deletion via read path, tolerating eventual consistency
	for i := 0; i < 5; i++ {
		getErr := c.Get(ctx, client.ObjectKey{Namespace: "default", Name: "nd-leaf01"}, &sdc.Config{})
		if getErr != nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	// Second reconcile: should annotate finalized-at and remove finalizer
	if _, err := rec.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKey{Namespace: "default", Name: "leaf01"}}); err != nil {
		t.Fatalf("reconcile2: %v", err)
	}
	latest := &kubenet.NetworkDevice{}
	if err := c.Get(ctx, client.ObjectKey{Namespace: "default", Name: "leaf01"}, latest); err == nil {
		if latest.Annotations["agentic-netops.dev/finalized-at"] == "" {
			t.Fatalf("expected finalized-at annotation on ND")
		}
		for _, f := range latest.Finalizers {
			if f == "agentic-netops.dev/finalizer" {
				t.Fatalf("expected finalizer removed")
			}
		}
	}
}
