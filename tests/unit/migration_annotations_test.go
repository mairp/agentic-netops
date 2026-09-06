package unit

import (
	"github.com/mairp/agentic-netops/pkg/migration"
	"strings"
	"testing"
)

func TestAnnotationsPresent(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID: "svcA",
		Type:      migration.ServiceVPLS,
		Tenant:    "TenA",
		RDRT:      &migration.RdRt{RD: "65000:1", ImportRT: []string{"65000:1"}, ExportRT: []string{"65000:1"}},
		L2VNI:     10001,
		Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "c1", VLAN: 10}, {Node: "leaf02", Attachment: "c2", VLAN: 10}},
	}
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Fatalf("validate: %v", err)
	}
	bundle, err := migration.Translate(&in)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	y := bundle.NetworkYAML
	for _, k := range []string{
		"agentic-netops.io/translator:",
		"agentic-netops.io/translator-version:",
		"agentic-netops.io/mapping-version:",
		"agentic-netops.io/migration-input-hash:",
		"agentic-netops.io/tenant:",
		"agentic-netops.io/service-type:",
	} {
		if !strings.Contains(y, k) {
			t.Fatalf("missing annotation key %s", k)
		}
	}
}

// US4 (T060): annotations carry the construct, the arrival vocabulary, and the
// limited-equivalence marker only for a VPWS source.
func TestAnnotationsCarryConstructAndProvenance(t *testing.T) {
	cases := []struct {
		name       string
		in         migration.ServiceInput
		wantType   migration.ServiceType
		wantSource migration.ServiceType
		wantLE     bool
	}{
		{
			name: "vpls→mac-vrf",
			in: migration.ServiceInput{
				ServiceID: "svc1",
				Type:      migration.ServiceVPLS,
				Tenant:    "A",
				RDRT:      &migration.RdRt{RD: "65000:100", ImportRT: []string{"65000:100"}, ExportRT: []string{"65000:100"}},
				L2VNI:     10010,
				Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "c1", VLAN: 10}, {Node: "leaf02", Attachment: "c2", VLAN: 10}},
			},
			wantType:   migration.ServiceMACVRF,
			wantSource: migration.LegacyVPLS,
			wantLE:     false,
		},
		{
			name: "vpws→mac-vrf (optin)",
			in: migration.ServiceInput{
				ServiceID: "svc3",
				Type:      migration.ServiceVPWS,
				Tenant:    "A",
				RDRT:      &migration.RdRt{RD: "65000:300", ImportRT: []string{"65000:300"}, ExportRT: []string{"65000:300"}},
				L2VNI:     10300,
				Policies:  migration.Policies{VPWSLimitedEquivalence: true},
				Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "c1", VLAN: 30}, {Node: "leaf02", Attachment: "c2", VLAN: 30}},
			},
			wantType:   migration.ServiceMACVRF,
			wantSource: migration.LegacyVPWS,
			wantLE:     true,
		},
		{
			name: "l3vpn→ip-vrf",
			in: migration.ServiceInput{
				ServiceID: "svc2",
				Type:      migration.ServiceL3VPN,
				Tenant:    "A",
				RDRT:      &migration.RdRt{RD: "65000:200", ImportRT: []string{"65000:200"}, ExportRT: []string{"65000:200"}},
				L3VNI:     10200,
				AF:        &migration.AddressFamilies{IPv4Prefixes: []string{"10.0.10.0/24"}},
				Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "c1", VRF: "vrf-svc2"}},
			},
			wantType:   migration.ServiceIPVRF,
			wantSource: migration.LegacyL3VPN,
			wantLE:     false,
		},
		{
			name: "irb→mac-vrf",
			in: migration.ServiceInput{
				ServiceID:  "irb1",
				Type:       migration.ServiceIRB,
				Tenant:     "B",
				RDRT:       &migration.RdRt{RD: "65000:401", ImportRT: []string{"65000:401"}, ExportRT: []string{"65000:401"}},
				L2VNI:      10401,
				L3VNI:      14001,
				IRBGateway: &migration.IRBGateway{VRF: "legacy", GatewayV4: "10.0.20.1/24"},
				Endpoints:  []migration.Endpoint{{Node: "leaf01", Attachment: "c1", VLAN: 20}, {Node: "leaf02", Attachment: "c2", VLAN: 20}},
			},
			wantType:   migration.ServiceMACVRF,
			wantSource: migration.LegacyIRB,
			wantLE:     false,
		},
	}
	for _, tc := range cases {
		in := tc.in
		if err := in.ValidateAllOrNothing(0, false); err != nil {
			t.Fatalf("%s: validate: %v", tc.name, err)
		}
		out, err := migration.Translate(&in)
		if err != nil {
			t.Fatalf("%s: translate: %v", tc.name, err)
		}
		anns := out.Annotations
		if anns["agentic-netops.io/service-type"] != string(tc.wantType) {
			t.Fatalf("%s: service-type annotation = %q, want %q", tc.name, anns["agentic-netops.io/service-type"], string(tc.wantType))
		}
		if anns["agentic-netops.io/source-service-type"] != string(tc.wantSource) {
			t.Fatalf("%s: source-service-type annotation = %q, want %q", tc.name, anns["agentic-netops.io/source-service-type"], string(tc.wantSource))
		}
		_, hasLE := anns["agentic-netops.io/limited-equivalence"]
		if hasLE != tc.wantLE {
			t.Fatalf("%s: limited-equivalence present=%v, want %v", tc.name, hasLE, tc.wantLE)
		}
	}
}
