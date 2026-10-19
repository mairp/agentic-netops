//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// server_test.go — apply and verify against an INJECTED transport (T145):
// the server must resolve a per-node transport and no caller may know which
// one it got (contracts/executor-transport.md §1). Op order is preserved and
// each op reaches the transport in plan order. T156 adds the /v1/nodes kind.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeTransport records every run call so a test can assert exactly which
// commands reached the node, in order, and with which stdin payload.
type fakeTransport struct {
	kindStr  string
	calls    []fakeCall
	failWith error
}

type fakeCall struct {
	argv  []string
	stdin string
}

// stdinBytes returns the captured stdin payload as bytes (for base64 checks).
func (c fakeCall) stdinBytes() []byte { return []byte(c.stdin) }

func (f *fakeTransport) run(_ context.Context, argv []string, stdin []byte) (string, string, error) {
	f.calls = append(f.calls, fakeCall{argv: argv, stdin: string(stdin)})
	if f.failWith != nil {
		return "", "boom", f.failWith
	}
	return "ok-out", "", nil
}

func (f *fakeTransport) kind() string {
	if f.kindStr == "" {
		return "docker"
	}
	return f.kindStr
}

func newFakeServer(tt *fakeTransport) *server {
	return &server{
		nodeMap: map[string]string{"leaf01": "clab-agentic-netops-fabric-leaf01"},
		trans:   map[string]transport{"leaf01": tt},
	}
}

func postJSON(t *testing.T, h http.Handler, path string, v any) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// TestApplyUsesInjectedTransportAndPreservesOpOrder: ops reach the injected
// transport in plan order and the response stays OK.
func TestApplyUsesInjectedTransportAndPreservesOpOrder(t *testing.T) {
	ft := &fakeTransport{}
	srv := newFakeServer(ft)
	req := ApplyRequest{
		Node: "leaf01",
		Ops: []ApplyOp{
			{Shell: []string{"echo first"}},
			{Shell: []string{"echo second"}},
			{VTYSh: []string{"show version"}},
		},
	}
	rec := postJSON(t, srv.mux(), "/v1/node/apply", req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	var resp ApplyResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !resp.OK {
		t.Fatalf("apply not OK: %+v", resp.Results)
	}
	if len(ft.calls) != 3 {
		t.Fatalf("transport saw %d calls, want 3: %+v", len(ft.calls), ft.calls)
	}
	if !strings.Contains(strings.Join(ft.calls[0].argv, " "), "echo first") ||
		!strings.Contains(strings.Join(ft.calls[1].argv, " "), "echo second") ||
		!strings.Contains(strings.Join(ft.calls[2].argv, " "), "show version") {
		t.Fatalf("op order not preserved: %+v", ft.calls)
	}
}

// TestVerifyUsesInjectedTransport: a verify check reaches the same transport
// and its stdout becomes the check's Actual.
func TestVerifyUsesInjectedTransport(t *testing.T) {
	ft := &fakeTransport{}
	srv := newFakeServer(ft)
	req := VerifyRequest{
		Node: "leaf01",
		Checks: []VerifyCheck{
			{Type: "redis-hget", RedisKey: "DEVICE_METADATA|localhost", RedisField: "bgp_asn", Expect: "65101"},
		},
	}
	rec := postJSON(t, srv.mux(), "/v1/node/verify", req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	var resp VerifyResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	// The fake prints "ok-out"; the check expects 65101, so the result must be
	// false-with-actual (the transport output is what was compared), proving
	// the verify path ran through the injected transport.
	if len(resp.Results) != 1 || resp.Results[0].Actual != "ok-out" {
		t.Fatalf("verify did not use the injected transport: %+v", resp)
	}
	if len(ft.calls) != 1 {
		t.Fatalf("transport saw %d calls, want 1", len(ft.calls))
	}
}

// TestUnknownNodeRefused: a node outside the site map never reaches any
// transport.
func TestUnknownNodeRefused(t *testing.T) {
	ft := &fakeTransport{}
	srv := newFakeServer(ft)
	rec := postJSON(t, srv.mux(), "/v1/node/apply", ApplyRequest{Node: "nope", Ops: []ApplyOp{{Shell: []string{"true"}}}})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	if len(ft.calls) != 0 {
		t.Fatalf("unknown node reached the transport: %+v", ft.calls)
	}
}

// TestNodesReturnTransportKind (T156): /v1/nodes names each node together
// with its transport kind, so the documented write path per node kind can be
// checked against the running executor (contracts/executor-transport.md §6).
func TestNodesReturnTransportKind(t *testing.T) {
	srv := &server{
		nodeMap: map[string]string{
			"leaf01":  "clab-agentic-netops-fabric-leaf01",
			"spine01": "clab-agentic-netops-fabric-spine01",
		},
		trans: map[string]transport{
			"leaf01":  &fakeTransport{kindStr: "ssh"},
			"spine01": &fakeTransport{kindStr: "docker"},
		},
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/nodes", nil)
	rec := httptest.NewRecorder()
	srv.mux().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var got struct {
		Nodes []struct {
			Name string `json:"name"`
			Kind string `json:"kind"`
		} `json:"nodes"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode /v1/nodes body %q: %v", rec.Body.String(), err)
	}
	if len(got.Nodes) != 2 {
		t.Fatalf("nodes = %+v, want 2 entries with name+kind", got.Nodes)
	}
	kinds := map[string]string{}
	for _, n := range got.Nodes {
		if n.Name == "" || n.Kind == "" {
			t.Fatalf("node entry missing name or kind: %+v", n)
		}
		kinds[n.Name] = n.Kind
	}
	if kinds["leaf01"] != "ssh" || kinds["spine01"] != "docker" {
		t.Fatalf("kinds = %v, want leaf01=ssh spine01=docker", kinds)
	}
}

// TestTransportFailureIsReportedPerOp: a transport error surfaces in the op
// result (stderr carried), and the response is not OK.
func TestTransportFailureIsReportedPerOp(t *testing.T) {
	ft := &fakeTransport{failWith: context.DeadlineExceeded}
	srv := newFakeServer(ft)
	rec := postJSON(t, srv.mux(), "/v1/node/apply", ApplyRequest{Node: "leaf01", Ops: []ApplyOp{{Shell: []string{"true"}}}})
	var resp ApplyResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.OK {
		t.Fatalf("apply reported OK despite transport failure: %+v", resp)
	}
}

// p4-acl-trial: sonic-vm renders SAI ACL bind points as a count-prefixed list,
// so redis-keys-match needs contains semantics for applied-view checks. A
// leading "~" on a match value requests contains; everything else stays exact.
func TestSatisfiesAll_ContainsTildeForListValuedAttributes(t *testing.T) {
	vals := "SAI_ACL_TABLE_ATTR_ACL_STAGE\nSAI_ACL_STAGE_INGRESS\nSAI_ACL_TABLE_ATTR_ACL_BIND_POINT_TYPE_LIST\n2:SAI_ACL_BIND_POINT_TYPE_PORT,SAI_ACL_BIND_POINT_TYPE_LAG\n"
	exact := map[string]string{
		"SAI_ACL_TABLE_ATTR_ACL_STAGE":                "SAI_ACL_STAGE_INGRESS",
		"SAI_ACL_TABLE_ATTR_ACL_BIND_POINT_TYPE_LIST": "SAI_ACL_BIND_POINT_TYPE_PORT",
	}
	if satisfiesAll(vals, exact) {
		t.Fatal("exact match must fail against the list encoding")
	}
	contains := map[string]string{
		"SAI_ACL_TABLE_ATTR_ACL_STAGE":                "SAI_ACL_STAGE_INGRESS",
		"SAI_ACL_TABLE_ATTR_ACL_BIND_POINT_TYPE_LIST": "~SAI_ACL_BIND_POINT_TYPE_PORT",
	}
	if !satisfiesAll(vals, contains) {
		t.Fatalf("contains match must hold against the list encoding: %q", vals)
	}
	if satisfiesAll(vals, map[string]string{"SAI_ACL_TABLE_ATTR_ACL_BIND_POINT_TYPE_LIST": "~SAI_ACL_BIND_POINT_TYPE_SWITCH"}) {
		t.Fatal("contains match must not match an absent element")
	}
	if !satisfiesAll("k\nv\n", nil) {
		t.Fatal("empty match must be count-only semantics (every object counts)")
	}
	if !satisfiesAll("", nil) {
		t.Fatal("empty match with no enumerated objects must count zero")
	}
}
