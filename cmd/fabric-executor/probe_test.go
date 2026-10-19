// SPDX-License-Identifier: Apache-2.0
// probe_test.go — pure probe-ping pieces, run WITHOUT the
// agentic_netops_k8s tag (probe.go is deliberately tag-free for this).
package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseProbeMapRoundTrip(t *testing.T) {
	raw := `{"leaf01/wan1":"clab-fabric-srv6-client01","leaf02/wan1":"clab-fabric-srv6-client02"}`
	m, err := parseProbeMap(raw)
	if err != nil {
		t.Fatalf("parseProbeMap: %v", err)
	}
	want := map[string]string{
		"leaf01/wan1": "clab-fabric-srv6-client01",
		"leaf02/wan1": "clab-fabric-srv6-client02",
	}
	if !reflect.DeepEqual(m, want) {
		t.Fatalf("got %v, want %v", m, want)
	}
}

func TestParseProbeMapEmpty(t *testing.T) {
	for _, raw := range []string{"", "   "} {
		m, err := parseProbeMap(raw)
		if err != nil {
			t.Fatalf("parseProbeMap(%q): %v", raw, err)
		}
		if len(m) != 0 {
			t.Fatalf("parseProbeMap(%q) = %v, want empty", raw, m)
		}
	}
}

func TestParseProbeMapInvalidJSON(t *testing.T) {
	if _, err := parseProbeMap("{not json"); err == nil {
		t.Fatal("expected error for invalid JSON")
	} else if !strings.Contains(err.Error(), "FABRIC_PROBE_MAP invalid") {
		t.Fatalf("error %q does not name the env var", err)
	}
}

func TestProbeHostRegistered(t *testing.T) {
	old := probeHosts
	defer func() { probeHosts = old }()
	probeHosts = map[string]string{"leaf01/wan1": "clab-fabric-srv6-client01"}
	host, err := probeHost("leaf01/wan1")
	if err != nil {
		t.Fatalf("probeHost: %v", err)
	}
	if host != "clab-fabric-srv6-client01" {
		t.Fatalf("got %q", host)
	}
}

func TestProbeHostUnregisteredExactError(t *testing.T) {
	old := probeHosts
	defer func() { probeHosts = old }()
	probeHosts = map[string]string{}
	_, err := probeHost("leaf01/wan9")
	if err == nil {
		t.Fatal("expected error for unregistered attachment")
	}
	if err.Error() != "no probe host for leaf01/wan9" {
		t.Fatalf("got %q, want %q", err.Error(), "no probe host for leaf01/wan9")
	}
}

func TestPingArgvFixedShape(t *testing.T) {
	got := pingArgv("192.168.2.2", 8900, 3)
	want := []string{"ping", "-c", "3", "-W", "3", "-s", "8900", "-M", "do", "192.168.2.2"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestPingArgvInterpolatesCountSizeAddrOnly(t *testing.T) {
	got := pingArgv("10.0.0.1", 1400, 5)
	want := []string{"ping", "-c", "5", "-W", "3", "-s", "1400", "-M", "do", "10.0.0.1"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// The argv is a slice handed to docker exec directly — no shell string — so a
// hostile addr cannot inject a second command.
func TestPingArgvAddrIsSingleArgNoShell(t *testing.T) {
	got := pingArgv("192.168.2.2; rm -rf /", 100, 1)
	if len(got) != 10 {
		t.Fatalf("addr not kept as one argv element: %v", got)
	}
	if got[len(got)-1] != "192.168.2.2; rm -rf /" {
		t.Fatalf("addr mangled: %v", got)
	}
	for _, a := range got {
		if strings.ContainsAny(a, "&|`$") {
			t.Fatalf("unexpected shell metachar in argv element %q", a)
		}
	}
}
