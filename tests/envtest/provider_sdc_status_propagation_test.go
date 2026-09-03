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

// TestProvider_SDCStatusPropagation verifies that SDC Config status drives NetworkDevice conditions.
func TestProvider_SDCStatusPropagation(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = kubenet.AddToScheme(scheme)
	_ = sdc.AddToScheme(scheme)

	ctx := context.TODO()
	nd := &kubenet.NetworkDevice{TypeMeta: metav1.TypeMeta{APIVersion: kubenet.GroupVersion.String(), Kind: "NetworkDevice"}, ObjectMeta: metav1.ObjectMeta{Name: "leaf01", Namespace: "default"}}
	// Case 1: Deviation present => Degraded=True
	cfg := &sdc.Config{TypeMeta: metav1.TypeMeta{APIVersion: sdc.GroupVersion.String(), Kind: "Config"}, ObjectMeta: metav1.ObjectMeta{Name: "nd-leaf01", Namespace: "default"}, Status: sdc.ConfigStatus{Deviation: []sdc.DeviationRecord{{Path: "/if", Message: "drift"}}}}

	// Pre-seed objects to avoid any scheme/restmapper surprises with Create+Get roundtrip
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&kubenet.NetworkDevice{}, &sdc.Config{}).WithObjects(nd, cfg).Build()
	rec := &sonicprovider.Reconciler{Client: c, Scheme: scheme}

	// sanity: object is retrievable from fake client prior to reconcile
	if err := c.Get(ctx, types.NamespacedName{Namespace: nd.Namespace, Name: nd.Name}, &kubenet.NetworkDevice{}); err != nil {
		t.Fatalf("pre-get nd: %v", err)
	}
	// and listed
	ndl := &kubenet.NetworkDeviceList{}
	if err := c.List(ctx, ndl); err != nil {
		t.Fatalf("pre-list: %v", err)
	}
	if len(ndl.Items) == 0 {
		t.Fatalf("pre-list: expected at least one item")
	}

	if _, err := rec.Reconcile(ctx, ctrl.Request{NamespacedName: types.NamespacedName{Namespace: nd.Namespace, Name: nd.Name}}); err != nil {
		t.Logf("err type: %T", err)
		t.Fatalf("reconcile: %v", err)
	}
	if err := c.Get(ctx, types.NamespacedName{Namespace: nd.Namespace, Name: nd.Name}, nd); err != nil {
		t.Fatalf("get nd: %v", err)
	}
	condsAny := nd.Status["conditions"]
	if condsAny == nil {
		t.Fatalf("expected conditions on NetworkDevice status")
	}
	// best-effort type assertion
	if conds, ok := condsAny.([]metav1.Condition); ok {
		found := false
		for _, cnd := range conds {
			if cnd.Type == "Degraded" && cnd.Status == metav1.ConditionTrue {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("expected Degraded=True condition from SDC deviation")
		}
	}

	// Case 2: Ready => Ready=True
	cfg.Status.Deviation = nil
	cfg.Status.Ready = true
	if err := c.Update(ctx, cfg); err != nil {
		t.Fatalf("update cfg: %v", err)
	}
	if _, err := rec.Reconcile(ctx, ctrl.Request{NamespacedName: types.NamespacedName{Namespace: nd.Namespace, Name: nd.Name}}); err != nil {
		t.Fatalf("reconcile2: %v", err)
	}
	if err := c.Get(ctx, types.NamespacedName{Namespace: nd.Namespace, Name: nd.Name}, nd); err != nil {
		t.Fatalf("get nd2: %v", err)
	}
	condsAny = nd.Status["conditions"]
	if conds, ok := condsAny.([]metav1.Condition); ok {
		found := false
		for _, cnd := range conds {
			if cnd.Type == "Ready" && cnd.Status == metav1.ConditionTrue {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("expected Ready=True condition from SDC Ready")
		}
	}
}
