//go:build !integration

package envtest

import (
	context "context"
	"os"
	"path/filepath"
	"testing"

	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/runtime/serializer/yaml"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/dynamic"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
)

// TestSRv6ServiceCRD_Envtest installs the CRD into a test API server and validates sample CRs
// using server-side dry-run (positive and negative cases).
func TestSRv6ServiceCRD_Envtest(t *testing.T) {
	t.Parallel()
	var (
		ctx = context.TODO()
	)

	// Determine envtest binaries; skip test when not available in CI.
	assets := os.Getenv("KUBEBUILDER_ASSETS")
	if assets == "" {
		// common default in many images
		if _, err := os.Stat("/usr/local/kubebuilder/bin/etcd"); err == nil {
			assets = "/usr/local/kubebuilder/bin"
		}
	}
	if assets == "" {
		t.Skip("envtest assets not found; set KUBEBUILDER_ASSETS to run this test")
	}
	// Start the envtest API server
	testEnv := &envtest.Environment{
		CRDDirectoryPaths: []string{
			filepath.Join("..", "..", "config", "crd", "bases"),
		},
		BinaryAssetsDirectory: assets,
	}
	cfg, err := testEnv.Start()
	if err != nil {
		t.Fatalf("failed to start envtest: %v", err)
	}
	t.Cleanup(func() {
		_ = testEnv.Stop()
	})

	// Ensure apiextensions scheme is registered for dry-run operations
	_ = apiextensionsv1.AddToScheme(runtime.NewScheme())

	dc, err := dynamic.NewForConfig(cfg)
	if err != nil {
		t.Fatalf("dynamic client: %v", err)
	}

	gvr := schemaFor("ainetops.io", "v1alpha1", "srv6services")

	// Positive sample
	posYAML, err := os.ReadFile(filepath.Join("..", "..", "config", "samples", "ainetops_v1alpha1_srv6service.yaml"))
	if err != nil {
		t.Fatalf("read sample: %v", err)
	}
	posObj := mustYAMLToUnstructured(t, posYAML)
	posObj.SetNamespace("default")
	// Dry-run create should succeed
	if _, err := dc.Resource(gvr).Namespace("default").Create(ctx, posObj, metav1.CreateOptions{DryRun: []string{"All"}}); err != nil {
		t.Fatalf("dry-run create positive sample failed: %v", err)
	}

	// Negative sample: duplicate attachments (violates CEL uniqueness rule)
	neg := posObj.DeepCopy()
	att, _, _ := unstructured.NestedSlice(neg.Object, "spec", "attachments")
	if len(att) != 2 {
		t.Fatalf("unexpected attachments len in sample: %d", len(att))
	}
	// make both nodes equal to violate uniqueness
	_ = unstructured.SetNestedField(att[1].(map[string]any), att[0].(map[string]any)["node"], "node")
	_ = unstructured.SetNestedSlice(neg.Object, att, "spec", "attachments")
	if _, err := dc.Resource(gvr).Namespace("default").Create(ctx, neg, metav1.CreateOptions{DryRun: []string{"All"}}); err == nil {
		t.Fatalf("expected dry-run create to fail for duplicate attachments, got nil error")
	}
}

func mustYAMLToUnstructured(t *testing.T, y []byte) *unstructured.Unstructured {
	t.Helper()
	dec := yaml.NewDecodingSerializer(unstructured.UnstructuredJSONScheme)
	obj := &unstructured.Unstructured{}
	_, _, err := dec.Decode(y, nil, obj)
	if err != nil {
		t.Fatalf("decode yaml: %v", err)
	}
	return obj
}

func schemaFor(group, version, resource string) schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: group, Version: version, Resource: resource}
}
