// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"testing"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// testEnv pairs a fake client with shared helpers for the pkg/kuid tests.
type testEnv struct {
	client.Client
}

// newScheme carries the built-in types (coordination Leases). The served
// *.be.kuid.dev claims are used as unstructured objects, which the fake
// client tracks without registration.
func newScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatalf("scheme: %v", err)
	}
	return scheme
}

func objectKey(name string) client.ObjectKey {
	return client.ObjectKey{Namespace: Namespace, Name: name}
}
