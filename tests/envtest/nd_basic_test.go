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

	"github.com/mairp/ainetops/pkg/kubenet"
)

func TestKubenetNetworkDeviceCreateGet(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = kubenet.AddToScheme(scheme)
	c := fake.NewClientBuilder().WithScheme(scheme).Build()
	ctx := context.TODO()
	nd := &kubenet.NetworkDevice{ObjectMeta: metav1.ObjectMeta{Name: "leaf01", Namespace: "default"}}
	if err := c.Create(ctx, nd); err != nil {
		t.Fatalf("create nd: %v", err)
	}
	get := &kubenet.NetworkDevice{}
	if err := c.Get(ctx, types.NamespacedName{Namespace: "default", Name: "leaf01"}, get); err != nil {
		t.Fatalf("get nd: %v", err)
	}
}
