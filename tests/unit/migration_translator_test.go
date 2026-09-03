package unit

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/pkg/migration"
)

func TestVPLSTranslation(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID: "svc1",
		Type:      migration.ServiceVPLS,
		Tenant:    "A",
		RDRT:      &migration.RdRt{RD: "65000:100", ImportRT: []string{"65000:100"}, ExportRT: []string{"65000:100"}},
		L2VNI:     10010,
		Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "client01", VLAN: 10}, {Node: "leaf02", Attachment: "client02", VLAN: 10}},
	}
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Fatalf("validate: %v", err)
	}
	out, err := migration.Translate(&in)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if !strings.Contains(out.NetworkYAML, "bridgeDomains") {
		t.Fatalf("expected bridgeDomains in YAML")
	}
	if !strings.Contains(out.NetworkYAML, "l2vni: 10010") {
		t.Fatalf("expected l2vni")
	}
}

func TestL3VPNTranslation(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID: "svc2",
		Type:      migration.ServiceL3VPN,
		Tenant:    "A",
		RDRT:      &migration.RdRt{RD: "65000:200", ImportRT: []string{"65000:200"}, ExportRT: []string{"65000:200"}},
		L3VNI:     10200,
		AF:        &migration.AddressFamilies{IPv4Prefixes: []string{"10.0.10.0/24"}},
		Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "client01", VRF: "vrf-svc2"}},
	}
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Fatalf("validate: %v", err)
	}
	out, err := migration.Translate(&in)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if !strings.Contains(out.NetworkYAML, "routers") {
		t.Fatalf("expected routers in YAML")
	}
	if !strings.Contains(out.NetworkYAML, "l3vni: 10200") {
		t.Fatalf("expected l3vni")
	}
}

func TestVPWSLimitedEquivalenceRequired(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID: "svc3",
		Type:      migration.ServiceVPWS,
		Tenant:    "A",
		RDRT:      &migration.RdRt{RD: "65000:300", ImportRT: []string{"65000:300"}, ExportRT: []string{"65000:300"}},
		L2VNI:     10300,
		Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "client01", VLAN: 30}, {Node: "leaf02", Attachment: "client02", VLAN: 30}},
		Policies:  migration.Policies{VPWSLimitedEquivalence: false},
	}
	if err := in.ValidateAllOrNothing(0, false); err == nil {
		t.Fatalf("expected validation error without opt-in")
	}
	in.Policies.VPWSLimitedEquivalence = true
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Fatalf("validate after opt-in: %v", err)
	}
	out, err := migration.Translate(&in)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if !strings.Contains(out.NetworkYAML, "limited-equivalence") {
		t.Fatalf("expected limited-equivalence annotation")
	}
}

func TestIRBTranslation(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID:  "svc4",
		Type:       migration.ServiceIRB,
		Tenant:     "B",
		RDRT:       &migration.RdRt{RD: "65000:401", ImportRT: []string{"65000:401"}, ExportRT: []string{"65000:401"}},
		L2VNI:      10401,
		L3VNI:      20401,
		IRBGateway: &migration.IRBGateway{VRF: "vrf-b1", GatewayV4: "10.0.20.1/24", GatewayV6: "2001:db8:20::1/64"},
		Endpoints:  []migration.Endpoint{{Node: "leaf01", Attachment: "client01", VLAN: 20}, {Node: "leaf02", Attachment: "client02", VLAN: 20}},
	}
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Fatalf("validate: %v", err)
	}
	out, err := migration.Translate(&in)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if !strings.Contains(out.NetworkYAML, "irb:") {
		t.Fatalf("expected irb block")
	}
}

func TestUnsupportedAndUnknownRejected(t *testing.T) {
	// Unsupported fields cause structured error
	in := migration.ServiceInput{
		ServiceID: "svc5",
		Type:      migration.ServiceVPLS,
		Tenant:    "A",
		RDRT:      &migration.RdRt{RD: "65000:500", ImportRT: []string{"65000:500"}, ExportRT: []string{"65000:500"}},
		L2VNI:     10500,
		Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "client01", VLAN: 50}, {Node: "leaf02", Attachment: "client02", VLAN: 50}},
	}
	// inject unsupported
	in.Unsupported.TEPolicy = true
	if err := in.ValidateAllOrNothing(0, false); err == nil {
		t.Fatalf("expected validation error for unsupported TE policy")
	}
}

func TestDeterministicHash(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID: "svc6",
		Type:      migration.ServiceVPLS,
		Tenant:    "A",
		RDRT:      &migration.RdRt{RD: "65000:600", ImportRT: []string{"65000:600"}, ExportRT: []string{"65000:600"}},
		L2VNI:     10600,
		Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "client01", VLAN: 60}, {Node: "leaf02", Attachment: "client02", VLAN: 60}},
	}
	h1, _ := in.CanonicalHash()
	// Re-marshal through JSON roundtrip to prove determinism
	b, _ := json.Marshal(in)
	var in2 migration.ServiceInput
	_ = json.Unmarshal(b, &in2)
	h2, _ := in2.CanonicalHash()
	if h1 != h2 {
		t.Fatalf("hashes differ: %s vs %s", h1, h2)
	}
}
