//go:build !integration

// Finalizer tests against a REAL API server (envtest), T358: the reconciler
// adds agentic-netops.dev/srv6 to a fresh SRv6Service BEFORE any claim — the
// first reconcile only adds the finalizer and requeues — and the second
// reconcile (no capability record installed) refuses CapabilityMissing with
// status.allocations still empty and the executor never called. Unlike
// srv6service_crd_envtest_test.go (admission only, dynamic client), this file
// starts its own envtest.Environment so a typed controller-runtime client can
// drive srv6service.Reconcile directly.
package envtest

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/controllers/srv6service"
	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
)

// srv6FinalizerAssets mirrors the shared harness's asset discovery.
func srv6FinalizerAssets() (string, error) {
	if a := os.Getenv("KUBEBUILDER_ASSETS"); a != "" {
		return a, nil
	}
	if _, err := os.Stat("/usr/local/kubebuilder/bin/etcd"); err == nil {
		return "/usr/local/kubebuilder/bin", nil
	}
	if hits, _ := filepath.Glob("/root/.local/share/kubebuilder-envtest/envtest-*-linux-amd64"); len(hits) > 0 {
		return hits[len(hits)-1], nil
	}
	return "", fmt.Errorf("envtest assets not found; set KUBEBUILDER_ASSETS")
}

// finalizerExecutor implements srv6service.Executor by recording only.
type finalizerExecutor struct {
	applies, verifies int
}

func (e *finalizerExecutor) Apply(ctx context.Context, node string, ops []fabricplan.Op) (*executorclient.ApplyResult, error) {
	e.applies++
	return &executorclient.ApplyResult{}, nil
}

func (e *finalizerExecutor) Verify(ctx context.Context, node string, checks []fabricplan.Check) (*executorclient.VerifyResult, error) {
	e.verifies++
	return &executorclient.VerifyResult{}, nil
}

// TestSRv6FinalizerAddedBeforeAnyClaim is T358 against a real API server.
func TestSRv6FinalizerAddedBeforeAnyClaim(t *testing.T) {
	assets, err := srv6FinalizerAssets()
	if err != nil {
		t.Skipf("envtest assets: %v", err)
	}
	testEnv := &envtest.Environment{
		CRDDirectoryPaths:     []string{filepath.Join("..", "..", "config", "crd", "bases")},
		BinaryAssetsDirectory: assets,
	}
	cfg, err := testEnv.Start()
	if err != nil {
		t.Fatalf("start envtest: %v", err)
	}
	defer func() { _ = testEnv.Stop() }()

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatalf("client-go scheme: %v", err)
	}
	if err := agenticnetopsv1alpha1.AddToScheme(scheme); err != nil {
		t.Fatalf("api scheme: %v", err)
	}
	kclient, err := client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		t.Fatalf("controller-runtime client: %v", err)
	}

	// The service object: the valid sample shape, through the typed client.
	svc := &agenticnetopsv1alpha1.SRv6Service{
		ObjectMeta: metav1.ObjectMeta{Name: "finalizer-first", Namespace: "default"},
	}
	svc.Spec = agenticnetopsv1alpha1.SRv6ServiceSpec{
		Tenant:     "acme",
		Construct:  agenticnetopsv1alpha1.ConstructIPVRF,
		Signalling: agenticnetopsv1alpha1.SignallingVPN,
		Attachments: []agenticnetopsv1alpha1.Attachment{
			{Node: "leaf01", Port: "wan1", Gateway: []agenticnetopsv1alpha1.GatewayPrefix{"192.168.1.1/24"}},
			{Node: "leaf02", Port: "wan1", Gateway: []agenticnetopsv1alpha1.GatewayPrefix{"192.168.2.1/24"}},
		},
	}
	if err := kclient.Create(context.Background(), svc); err != nil {
		t.Fatalf("create: %v", err)
	}
	key := types.NamespacedName{Name: svc.Name, Namespace: svc.Namespace}

	ex := &finalizerExecutor{}
	r := &srv6service.Reconciler{
		Client:    kclient,
		Scheme:    scheme,
		Log:       logr.Discard(),
		APIReader: kclient, // uncached: the ConfigMap is ABSENT here
		Facts:     srv6service.DefaultSiteFacts(),
		Executor:  ex,
	}

	// Reconcile 1: adds the finalizer and returns (requeues) — nothing else.
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: key}); err != nil {
		t.Fatalf("first reconcile: %v", err)
	}
	var afterFirst agenticnetopsv1alpha1.SRv6Service
	if err := kclient.Get(context.Background(), key, &afterFirst); err != nil {
		t.Fatalf("get after first reconcile: %v", err)
	}
	if !hasDevFinalizer(&afterFirst) {
		t.Fatalf("finalizer %s not added on the first reconcile: %v", agenticnetopsv1alpha1.SRv6Finalizer, afterFirst.Finalizers)
	}

	// Reconcile 2: site validation passes, the capability record is
	// ABSENT (no ConfigMap was installed) → the terminal C5 refusal.
	if _, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: key}); err != nil {
		t.Fatalf("second reconcile: %v", err)
	}
	var afterSecond agenticnetopsv1alpha1.SRv6Service
	if err := kclient.Get(context.Background(), key, &afterSecond); err != nil {
		t.Fatalf("get after second reconcile: %v", err)
	}
	cond := readyConditionOf(&afterSecond)
	if cond == nil || cond.Reason != reasons.ReasonCapabilityMissing {
		t.Fatalf("Ready reason = %+v, want %s from the missing capability record", cond, reasons.ReasonCapabilityMissing)
	}
	// Nothing was claimed: no allocations recorded, executor untouched.
	if afterSecond.Status.Allocations != nil {
		t.Errorf("status.allocations = %+v before the capability gate passed; nothing may be claimed", afterSecond.Status.Allocations)
	}
	if ex.applies != 0 || ex.verifies != 0 {
		t.Errorf("executor saw %d applies / %d verifies before the capability gate; want none", ex.applies, ex.verifies)
	}
	// The finalizer is still there (the service is not being deleted).
	if !hasDevFinalizer(&afterSecond) {
		t.Error("finalizer lost across the refused reconcile")
	}
}

// hasDevFinalizer reports whether the object carries agentic-netops.dev/srv6.
func hasDevFinalizer(svc *agenticnetopsv1alpha1.SRv6Service) bool {
	for _, f := range svc.Finalizers {
		if f == agenticnetopsv1alpha1.SRv6Finalizer {
			return true
		}
	}
	return false
}

// readyConditionOf returns the Ready condition of the status, or nil.
func readyConditionOf(svc *agenticnetopsv1alpha1.SRv6Service) *metav1.Condition {
	for i := range svc.Status.Conditions {
		if svc.Status.Conditions[i].Type == "Ready" {
			return &svc.Status.Conditions[i]
		}
	}
	return nil
}
