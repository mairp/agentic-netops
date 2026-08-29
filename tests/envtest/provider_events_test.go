//go:build !integration

package envtest

import (
	"context"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	ctrl "sigs.k8s.io/controller-runtime"

	"github.com/mairp/ainetops/controllers/sonicprovider"
	"github.com/mairp/ainetops/pkg/kubenet"
	"github.com/mairp/ainetops/pkg/sdc"
)

type capturingRecorder struct{ events []string }

func (c *capturingRecorder) Eventf(object runtime.Object, eventtype, reason, messageFmt string, args ...any) {
	c.events = append(c.events, reason)
}

func TestProvider_EmitsDeviationObservedEvent(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = kubenet.AddToScheme(scheme)
	_ = sdc.AddToScheme(scheme)

	ctx := context.TODO()
	nd := &kubenet.NetworkDevice{TypeMeta: metav1.TypeMeta{APIVersion: kubenet.GroupVersion.String(), Kind: "NetworkDevice"}, ObjectMeta: metav1.ObjectMeta{Name: "leaf01", Namespace: "default"}}
	cfg := &sdc.Config{TypeMeta: metav1.TypeMeta{APIVersion: sdc.GroupVersion.String(), Kind: "Config"}, ObjectMeta: metav1.ObjectMeta{Name: "nd-leaf01", Namespace: "default"}, Status: sdc.ConfigStatus{Deviation: []sdc.DeviationRecord{{Path: "/if", Message: "drift"}}}}
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&kubenet.NetworkDevice{}, &sdc.Config{}).WithObjects(nd, cfg).Build()
	rec := &sonicprovider.Reconciler{Client: c, Scheme: scheme}
	cr := &capturingRecorder{}
	rec.Recorder = cr

	if _, err := rec.Reconcile(ctx, ctrl.Request{NamespacedName: types.NamespacedName{Namespace: nd.Namespace, Name: nd.Name}}); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if len(cr.events) == 0 {
		t.Fatalf("expected one or more events to be recorded")
	}
	found := false
	for _, r := range cr.events {
		if r == "DeviationObserved" { found = true; break }
	}
	if !found {
		t.Fatalf("expected DeviationObserved event, got %v", cr.events)
	}
}
