package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// postTranslate runs handleTranslate against a JSON body and decodes the
// response into status + body map.
func postTranslate(t *testing.T, body string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/translate", strings.NewReader(body))
	rec := httptest.NewRecorder()
	handleTranslate(rec, req)
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode response %q: %v", rec.Body.String(), err)
	}
	return rec.Code, out
}

// srv6Input is a minimal valid srv6 ip-vrf (identifiers are allocated by the
// fabric, so none are needed).
const srv6Input = `{
  "serviceId": "acme-routed",
  "type": "ip-vrf",
  "transport": "srv6",
  "signalling": "vpn",
  "tenant": "acme",
  "endpoints": [
    {"node": "leaf01", "attachment": "wan1", "prefixes": ["2001:db8:3::30/127"]},
    {"node": "leaf02", "attachment": "wan1", "prefixes": ["2001:db8:4::40/127"]}
  ],
  "preferredSpine": "spine01"
}`

// vxlanInput is a minimal valid vxlan ip-vrf (transport omitted).
const vxlanInput = `{
  "serviceId": "c_ipvrf_50",
  "type": "ip-vrf",
  "tenant": "initech",
  "rdRt": {"rd": "65000:250", "importRT": ["65000:250"], "exportRT": ["65000:250"]},
  "l3vni": 10250,
  "addressFamilies": {"ipv4Prefixes": ["10.50.0.0/24"]},
  "endpoints": [
    {"node": "leaf01", "attachment": "wan1", "vrf": "vrf-initech"}
  ]
}`

func kindsOf(t *testing.T, body map[string]any) []string {
	t.Helper()
	raw, ok := body["kinds"]
	if !ok {
		t.Fatalf("response has no kinds field: %v", body)
	}
	arr, ok := raw.([]any)
	if !ok {
		t.Fatalf("kinds is not an array: %v", raw)
	}
	out := make([]string, 0, len(arr))
	for _, k := range arr {
		s, _ := k.(string)
		out = append(out, s)
	}
	return out
}

// T453: an srv6 input yields kind SRv6Service.
func TestHandleTranslate_SRV6Kind(t *testing.T) {
	code, body := postTranslate(t, srv6Input)
	if code != http.StatusOK {
		t.Fatalf("status = %d, body = %v", code, body)
	}
	if got := kindsOf(t, body); len(got) != 1 || got[0] != "SRv6Service" {
		t.Fatalf("kinds = %v, want [SRv6Service]", got)
	}
}

// T453: a vxlan input (transport omitted) still yields kind Network.
func TestHandleTranslate_VxlanKind(t *testing.T) {
	code, body := postTranslate(t, vxlanInput)
	if code != http.StatusOK {
		t.Fatalf("status = %d, body = %v", code, body)
	}
	if got := kindsOf(t, body); len(got) != 1 || got[0] != "Network" {
		t.Fatalf("kinds = %v, want [Network]", got)
	}
}

// T453: a mixed batch reports one kind per input, in input order.
func TestHandleTranslate_MixedBatchKinds(t *testing.T) {
	code, body := postTranslate(t, "["+vxlanInput+","+srv6Input+"]")
	if code != http.StatusOK {
		t.Fatalf("status = %d, body = %v", code, body)
	}
	want := []string{"Network", "SRv6Service"}
	if got := kindsOf(t, body); len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("kinds = %v, want %v", got, want)
	}
}
