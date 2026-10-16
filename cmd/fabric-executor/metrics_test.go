//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// metrics_test.go — the applied-op counter (T157): every successfully applied
// op moves the counter; verify never does.
package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

// TestCounterMovesOnApplyNotVerify: apply ops are counted, verify checks are
// not (they read; they must not look like writes in the metrics).
func TestCounterMovesOnApplyNotVerify(t *testing.T) {
	ft := &fakeTransport{}
	srv := newFakeServer(ft)
	before := counterValue(t, opsApplied)

	rec := postJSON(t, srv.mux(), "/v1/node/apply", ApplyRequest{
		Node: "leaf01",
		Ops:  []ApplyOp{{Shell: []string{"true"}}, {Shell: []string{"true"}}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d", rec.Code)
	}
	after := counterValue(t, opsApplied)
	if after-before != 2 {
		t.Fatalf("counter moved %v for 2 applied ops, want 2", after-before)
	}

	// A FAILED op must not count as applied.
	ft.failWith = errFake
	rec = postJSON(t, srv.mux(), "/v1/node/apply", ApplyRequest{
		Node: "leaf01",
		Ops:  []ApplyOp{{Shell: []string{"false"}}},
	})
	ft.failWith = nil
	if counterValue(t, opsApplied) != after {
		t.Fatalf("failed op moved the counter")
	}

	// Verify must never move it.
	rec = postJSON(t, srv.mux(), "/v1/node/verify", VerifyRequest{
		Node:   "leaf01",
		Checks: []VerifyCheck{{Type: "redis-exists", RedisKey: "DEVICE_METADATA|localhost"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("verify status = %d", rec.Code)
	}
	if counterValue(t, opsApplied) != after {
		t.Fatalf("verify moved the applied-op counter")
	}
}

// TestMetricsEndpointExposed: /metrics is served and names the counter.
func TestMetricsEndpointExposed(t *testing.T) {
	srv := newFakeServer(&fakeTransport{})
	rec := httptest.NewRecorder()
	srv.mux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("/metrics status = %d", rec.Code)
	}
	if !contains(rec.Body.String(), "fabric_executor_ops_applied_total") {
		t.Fatalf("/metrics does not expose the applied-op counter")
	}
}

// counterValue reads the counter's current value through its dto write path.
func counterValue(t *testing.T, c prometheus.Counter) float64 {
	t.Helper()
	var m dto.Metric
	if err := c.Write(&m); err != nil {
		t.Fatalf("write counter: %v", err)
	}
	return m.GetCounter().GetValue()
}

type errFakeStruct struct{}

func (errFakeStruct) Error() string { return "fake failure" }

var errFake = errFakeStruct{}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (func() bool {
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	})()
}
