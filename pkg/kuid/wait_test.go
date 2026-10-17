// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"context"
	"strings"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// seedClaim creates a claim object (optionally with a status) directly so
// wait tests do not depend on a live kuid-server controller.
func seedClaim(t *testing.T, env *testEnv, pool Pool, name string, status map[string]any) {
	t.Helper()
	u := newClaimObject(pool)
	u.SetNamespace(Namespace)
	u.SetName(name)
	u.SetLabels(map[string]string{LabelCorrelationID: "corr-1", LabelManagedBy: ManagedBy})
	u.Object["spec"] = claimSpec(pool)
	if status != nil {
		u.Object["status"] = status
	}
	if err := env.Client.Create(context.Background(), u); err != nil {
		t.Fatalf("seed claim: %v", err)
	}
}

func TestWaitForClaimReturnsAllocatedID(t *testing.T) {
	env := newTestClient(t)
	ref := ClaimRef{Pool: ServiceIDPool, Name: "claim-ready"}
	seedClaim(t, env, ServiceIDPool, ref.Name, map[string]any{"id": int64(7)})

	res, err := WaitForClaim(context.Background(), env.Client, ref, 2*PollInterval)
	if err != nil {
		t.Fatalf("wait: %v", err)
	}
	if res.ID != 7 {
		t.Fatalf("id = %d, want 7", res.ID)
	}
}

func TestWaitForClaimReturnsAllocatedAddress(t *testing.T) {
	env := newTestClient(t)
	ref := ClaimRef{Pool: ClientV4Pool, Name: "claim-addr"}
	seedClaim(t, env, ClientV4Pool, ref.Name, map[string]any{"address": "192.168.1.1/24"})

	res, err := WaitForClaim(context.Background(), env.Client, ref, 2*PollInterval)
	if err != nil {
		t.Fatalf("wait: %v", err)
	}
	if res.Address != "192.168.1.1/24" {
		t.Fatalf("address = %q", res.Address)
	}
}

func TestWaitForClaimReturnsAllocatedPrefix(t *testing.T) {
	// The served ipam family answers a dynamicPrefix claim with
	// status.prefix (live 2026-10-16: IPClaim
	// srv6-client-v4-claim-srv6-ip-vrf-vpn-leaf01-wan1 carried
	// status.prefix 192.168.0.0/24 with Ready=True while the wait still
	// timed out). The prefix IS the allocated value.
	env := newTestClient(t)
	ref := ClaimRef{Pool: ClientV4Pool, Name: "claim-prefix"}
	seedClaim(t, env, ClientV4Pool, ref.Name, map[string]any{
		"prefix": "192.168.0.0/24",
		"conditions": []any{map[string]any{
			"type": "Ready", "status": "True", "reason": "Ready",
		}},
	})

	res, err := WaitForClaim(context.Background(), env.Client, ref, 2*PollInterval)
	if err != nil {
		t.Fatalf("wait: %v", err)
	}
	if res.Address != "192.168.0.0/24" {
		t.Fatalf("address = %q, want the claimed /24", res.Address)
	}
}

func TestWaitForClaimTimesOutAndNamesTheClaim(t *testing.T) {
	env := newTestClient(t)
	ref := ClaimRef{Pool: ServiceIDPool, Name: "claim-pending"}
	seedClaim(t, env, ServiceIDPool, ref.Name, nil) // no status yet

	_, err := WaitForClaim(context.Background(), env.Client, ref, 3*PollInterval)
	if !IsTimeout(err) {
		t.Fatalf("want timeout, got %v", err)
	}
	if !strings.Contains(err.Error(), ref.Name) || !strings.Contains(err.Error(), ServiceIDPool.Name) {
		t.Errorf("timeout must name claim and pool: %v", err)
	}
}

func TestWaitForClaimRespectsCancelledContext(t *testing.T) {
	env := newTestClient(t)
	ref := ClaimRef{Pool: ServiceIDPool, Name: "claim-never"}
	seedClaim(t, env, ServiceIDPool, ref.Name, nil)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := WaitForClaim(ctx, env.Client, ref, 10*time.Second); !IsTimeout(err) {
		t.Fatalf("want timeout on cancelled ctx, got %v", err)
	}
}

func TestWaitForClaimSeesStatusAppearLater(t *testing.T) {
	env := newTestClient(t)
	ref := ClaimRef{Pool: ServiceIDPool, Name: "claim-late"}
	seedClaim(t, env, ServiceIDPool, ref.Name, nil)

	go func() {
		// Simulate the kuid-server controller allocating after one poll.
		time.Sleep(150 * time.Millisecond)
		u := &unstructured.Unstructured{}
		u.SetGroupVersionKind(newClaimObject(ServiceIDPool).GroupVersionKind())
		if err := env.Client.Get(context.Background(), objectKey(ref.Name), u); err != nil {
			return
		}
		u.Object["status"] = map[string]any{"id": int64(42)}
		_ = env.Client.Update(context.Background(), u)
	}()

	res, err := WaitForClaim(context.Background(), env.Client, ref, 5*time.Second)
	if err != nil {
		t.Fatalf("wait: %v", err)
	}
	if res.ID != 42 {
		t.Fatalf("id = %d, want 42", res.ID)
	}
}
