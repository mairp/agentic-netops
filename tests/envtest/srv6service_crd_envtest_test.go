//go:build !integration

// Package envtest exercises the SRv6Service CRD against a real API server:
// one case per admission rule A1-A12 of
// specs/004-srv6-service-requests/contracts/srv6service-crd.md §2, plus the
// accepted sample. The controller rules C1-C8 need the site and live in
// controllers/srv6service (not admission).
package envtest

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/runtime/serializer/yaml"
	"k8s.io/client-go/dynamic"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
)

const (
	srv6Group    = "agentic-netops.io"
	srv6Version  = "v1alpha1"
	srv6Resource = "srv6services"
)

var (
	envOnce  sync.Once
	envCfg   *envtestConfig
	envStart error
	// envStop stops the shared environment started by envOnce. Without it
	// the etcd/kube-apiserver pair outlives every green run (the harness
	// had no Stop at all), which keeps a systemd transient scope alive
	// after the test binary exits and makes the next gate execution of the
	// same command collide ("already loaded or has a fragment file").
	envStop func()
)

type envtestConfig struct {
	dc dynamic.Interface
}

// TestMain tears the shared environment down after the whole package's
// tests have run (per-test cleanups own their own environments).
func TestMain(m *testing.M) {
	code := m.Run()
	if envStop != nil {
		envStop()
	}
	os.Exit(code)
}

// srv6Env starts envtest once per test binary and installs the generated CRD.
func srv6Env(t *testing.T) *envtestConfig {
	t.Helper()
	envOnce.Do(func() {
		assets := os.Getenv("KUBEBUILDER_ASSETS")
		if assets == "" {
			if _, err := os.Stat("/usr/local/kubebuilder/bin/etcd"); err == nil {
				assets = "/usr/local/kubebuilder/bin"
			}
		}
		if assets == "" {
			// The pinned envtest the Makefile exports (T294), so a bare
			// `go test ./...` finds it without the env variable — the same
			// discovery scripts/ci/run_suites.sh does.
			if hits, _ := filepath.Glob("/root/.local/share/kubebuilder-envtest/envtest-*-linux-amd64"); len(hits) > 0 {
				assets = hits[len(hits)-1]
			}
		}
		if assets == "" {
			envStart = fmt.Errorf("envtest assets not found; set KUBEBUILDER_ASSETS")
			return
		}
		testEnv := &envtest.Environment{
			CRDDirectoryPaths: []string{
				filepath.Join("..", "..", "config", "crd", "bases"),
			},
			BinaryAssetsDirectory: assets,
		}
		cfg, err := testEnv.Start()
		if err != nil {
			envStart = fmt.Errorf("start envtest: %w", err)
			return
		}
		dc, err := dynamic.NewForConfig(cfg)
		if err != nil {
			envStart = fmt.Errorf("dynamic client: %w", err)
			return
		}
		envCfg = &envtestConfig{dc: dc}
		envStop = func() { _ = testEnv.Stop() }
	})
	if envStart != nil {
		t.Fatalf("envtest harness: %v", envStart)
	}
	return envCfg
}

func srv6GVR() schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: srv6Group, Version: srv6Version, Resource: srv6Resource}
}

// baseService returns a valid ip-vrf/vpn object: two distinct leaf
// attachments on ports the site port map knows, each with its leaf-side
// gateway prefix. No identifier is typed anywhere (rule A12).
func baseService(name string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": srv6Group + "/" + srv6Version,
		"kind":       "SRv6Service",
		"metadata": map[string]any{
			"name":      name,
			"namespace": "default",
		},
		"spec": map[string]any{
			"tenant":     "acme",
			"construct":  "ip-vrf",
			"signalling": "vpn",
			"attachments": []any{
				map[string]any{
					"node":    "leaf01",
					"port":    "wan1",
					"gateway": []any{"192.168.1.1/24"},
				},
				map[string]any{
					"node":    "leaf02",
					"port":    "wan1",
					"gateway": []any{"192.168.2.1/24"},
				},
			},
		},
	}}
}

func patchSpec(obj *unstructured.Unstructured, mut func(spec map[string]any)) {
	spec, _, _ := unstructured.NestedMap(obj.Object, "spec")
	mut(spec)
	_ = unstructured.SetNestedMap(obj.Object, spec, "spec")
}

// expectRejected applies obj (dry-run, strict) and requires the rule message
// in the API server error.
func expectRejected(t *testing.T, c *envtestConfig, obj *unstructured.Unstructured, msg string) {
	t.Helper()
	_, err := c.dc.Resource(srv6GVR()).Namespace(obj.GetNamespace()).Create(
		context.Background(), obj,
		metav1.CreateOptions{DryRun: []string{metav1.DryRunAll}, FieldValidation: metav1.FieldValidationStrict})
	if err == nil {
		t.Fatalf("expected rejection with %q, got accepted", msg)
	}
	if !strings.Contains(err.Error(), msg) {
		t.Fatalf("expected rejection message %q in error, got: %v", msg, err)
	}
}

// TestSRv6ServiceAdmissionRules runs one case per admission rule
// (contracts/srv6service-crd.md §2 A1-A12) against the generated CRD in a
// real API server.
func TestSRv6ServiceAdmissionRules(t *testing.T) {
	c := srv6Env(t)
	ctx := context.Background()

	t.Run("positive-sample-is-accepted", func(t *testing.T) {
		raw, err := os.ReadFile(filepath.Join("..", "..", "config", "samples", "srv6service-ip-vrf-vpn.yaml"))
		if err != nil {
			t.Fatalf("read sample: %v", err)
		}
		obj, _, err := yaml.NewDecodingSerializer(unstructured.UnstructuredJSONScheme).Decode(raw, nil, nil)
		if err != nil {
			t.Fatalf("decode sample: %v", err)
		}
		u := obj.(*unstructured.Unstructured)
		u.SetNamespace("default")
		if _, err := c.dc.Resource(srv6GVR()).Namespace("default").Create(ctx, u,
			metav1.CreateOptions{DryRun: []string{metav1.DryRunAll}, FieldValidation: metav1.FieldValidationStrict}); err != nil {
			t.Fatalf("sample rejected: %v", err)
		}
	})

	t.Run("A1-tenant-must-be-a-dns-label", func(t *testing.T) {
		obj := baseService("a1-tenant")
		patchSpec(obj, func(spec map[string]any) { spec["tenant"] = "Acme" })
		expectRejected(t, c, obj, "tenant must be a DNS label")
	})

	t.Run("A2-construct-must-be-ip-vrf-or-mac-vrf", func(t *testing.T) {
		obj := baseService("a2-construct")
		patchSpec(obj, func(spec map[string]any) { spec["construct"] = "lan-vrf" })
		expectRejected(t, c, obj, "construct must be ip-vrf or mac-vrf")
	})

	t.Run("A3-signalling-must-be-vpn-or-evpn", func(t *testing.T) {
		obj := baseService("a3-signalling")
		patchSpec(obj, func(spec map[string]any) { spec["signalling"] = "bgp" })
		expectRejected(t, c, obj, "signalling must be vpn or evpn")
	})

	t.Run("A4-mac-vrf-refuses-vpn-signalling", func(t *testing.T) {
		obj := baseService("a4-macvrf-vpn")
		patchSpec(obj, func(spec map[string]any) {
			spec["construct"] = "mac-vrf"
			spec["vlan"] = int64(130)
		})
		expectRejected(t, c, obj, "mac-vrf over srv6 uses evpn signalling")
	})

	t.Run("A5-exactly-two-attachments", func(t *testing.T) {
		obj := baseService("a5-one-attachment")
		patchSpec(obj, func(spec map[string]any) {
			spec["attachments"] = spec["attachments"].([]any)[:1]
		})
		expectRejected(t, c, obj, "exactly two attachments are required")
	})

	t.Run("A6-attachments-on-distinct-nodes", func(t *testing.T) {
		obj := baseService("a6-same-node")
		atts := obj.Object["spec"].(map[string]any)["attachments"].([]any)
		atts[1].(map[string]any)["node"] = "leaf01"
		expectRejected(t, c, obj, "attachments must be on distinct nodes")
	})

	t.Run("A7-gateway-must-be-a-prefix", func(t *testing.T) {
		obj := baseService("a7-gateway")
		patchSpec(obj, func(spec map[string]any) {
			spec["attachments"] = []any{
				map[string]any{"node": "leaf01", "port": "wan1", "gateway": []any{"2001:db8:3::30"}},
				map[string]any{"node": "leaf02", "port": "wan1", "gateway": []any{"192.168.2.1/24"}},
			}
		})
		expectRejected(t, c, obj, "gateway must be an IP prefix")
	})

	t.Run("A8-vlan-iff-mac-vrf", func(t *testing.T) {
		obj := baseService("a8-vlan-ip-vrf")
		patchSpec(obj, func(spec map[string]any) { spec["vlan"] = int64(130) })
		expectRejected(t, c, obj, "vlan is required for mac-vrf and not allowed for ip-vrf")
	})

	t.Run("A9-ip-vrf-needs-gateway-on-both", func(t *testing.T) {
		obj := baseService("a9-no-gateway")
		patchSpec(obj, func(spec map[string]any) {
			spec["attachments"] = []any{
				map[string]any{"node": "leaf01", "port": "wan1"},
				map[string]any{"node": "leaf02", "port": "wan1", "gateway": []any{"192.168.2.1/24"}},
			}
		})
		expectRejected(t, c, obj, "ip-vrf attachments need a gateway prefix")
	})

	t.Run("A10-spines-must-differ", func(t *testing.T) {
		obj := baseService("a10-spines")
		patchSpec(obj, func(spec map[string]any) {
			spec["path"] = map[string]any{"preferredSpine": "spine01", "alternateSpine": "spine01"}
		})
		expectRejected(t, c, obj, "preferred and alternate spine must differ")
	})

	t.Run("A11-tenant-construct-signalling-immutable", func(t *testing.T) {
		obj := baseService("a11-immutable")
		created, err := c.dc.Resource(srv6GVR()).Namespace("default").Create(ctx, obj, metav1.CreateOptions{})
		if err != nil {
			t.Fatalf("create base object: %v", err)
		}
		obj = created // carries the resourceVersion the dry-run updates below need
		mutations := []struct {
			field string
			value any
			msg   string
		}{
			{"tenant", "otherco", "tenant is immutable"},
			{"construct", "mac-vrf", "construct is immutable"},
			{"signalling", "evpn", "signalling is immutable"},
		}
		for _, m := range mutations {
			updated := obj.DeepCopy()
			patchSpec(updated, func(spec map[string]any) { spec[m.field] = m.value })
			_, err := c.dc.Resource(srv6GVR()).Namespace("default").Update(ctx, updated, metav1.UpdateOptions{DryRun: []string{metav1.DryRunAll}})
			if err == nil {
				t.Fatalf("expected %s update to be rejected with %q", m.field, m.msg)
			}
			if !strings.Contains(err.Error(), m.msg) {
				t.Fatalf("expected %q in error, got: %v", m.msg, err)
			}
		}
		// A non-identifier field (a gateway prefix) may change.
		updated := obj.DeepCopy()
		patchSpec(updated, func(spec map[string]any) {
			spec["attachments"] = []any{
				map[string]any{"node": "leaf01", "port": "wan1", "gateway": []any{"192.168.1.9/24"}},
				map[string]any{"node": "leaf02", "port": "wan1", "gateway": []any{"192.168.2.1/24"}},
			}
		})
		if _, err := c.dc.Resource(srv6GVR()).Namespace("default").Update(ctx, updated, metav1.UpdateOptions{DryRun: []string{metav1.DryRunAll}}); err != nil {
			t.Fatalf("gateway update should be allowed (US3 scenario 9), got: %v", err)
		}
	})

	t.Run("A12-unknown-fields-rejected", func(t *testing.T) {
		// Identifiers are allocated, not typed: a hand-typed locator is not a
		// field of the schema at all, and strict server-side decoding refuses
		// the unknown key instead of silently pruning it.
		obj := baseService("a12-typed-locator")
		patchSpec(obj, func(spec map[string]any) { spec["locatorPrefix"] = "fcbb:bbbb:1::/48" })
		_, err := c.dc.Resource(srv6GVR()).Namespace("default").Create(ctx, obj,
			metav1.CreateOptions{DryRun: []string{metav1.DryRunAll}, FieldValidation: metav1.FieldValidationStrict})
		if err == nil {
			t.Fatal("expected unknown field spec.locatorPrefix to be rejected")
		}
		if !strings.Contains(err.Error(), "locatorPrefix") {
			t.Fatalf("expected the unknown field named in the error, got: %v", err)
		}
	})
}
