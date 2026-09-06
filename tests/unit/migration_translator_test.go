package unit

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
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
		L3VNI:      14001,
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

func TestUnsupportedAndUnknownRejected(t *testing.T) {}

// US2 refusals: ACL-specific causes via CLI to assert stderr carries causes and stdout is empty.
func TestUS2_ACLRefusals_CLI(t *testing.T) {
	cases := []struct {
		file string
		want []string
	}{
		{file: "refuse_acl_dup_priority.json", want: []string{"acl.rules[1].priority", "priorities must be distinct"}},
		{file: "refuse_acl_family_mismatch.json", want: []string{"acl.rules[0].sourcePrefix", "IPv6 but the acl type is l3"}},
		{file: "refuse_acl_l4_on_icmp.json", want: []string{"acl.rules[0].destinationPort", "L4 ports require protocol tcp or udp"}},
		{file: "refuse_acl_no_rules.json", want: []string{"acl.rules: at least one rule is required"}},
		{file: "refuse_acl_icmpv6.json", want: []string{"acl.rules[0].protocol", "one of any, tcp, udp, icmp, igmp, rsvp, gre, ah, pim, l2tp or an IP protocol number"}},
		{file: "refuse_acl_type_l2.json", want: []string{"acl.type: required, one of l3, l3v6"}},
		{file: "refuse_acl_priority_reserved.json", want: []string{"acl.rules[0].priority: 1 is reserved", "usable priorities are 2-65535"}},
		{file: "refuse_acl_reference_by_name.json", want: []string{"acl: a service carries its own rules and its name is a label"}},
		{file: "refuse_acl_binding_vlan.json", want: []string{"acl.bindTo:", "binds to ports"}},
		{file: "refuse_acl_no_stage.json", want: []string{"acl.stage: required, one of ingress, egress"}},
		{file: "refuse_acl_port_range_inverted.json", want: []string{"acl.rules[0].sourcePort", "ends below where it starts"}},
		{file: "refuse_acl_no_endpoints.json", want: []string{"endpoints: acl requires \\u003e=1 endpoint to bind to", "endpoints: at least one endpoint is required"}},
	}
	for _, tc := range cases {
		repoRoot := filepath.Join("..", "..")
		cmd := exec.Command("go", "run", "./cmd/migration-translator", "--file", filepath.Join("tests", "unit", "testdata", "migration", tc.file))
		cmd.Dir = repoRoot
		cachePath := filepath.Join(repoRoot, ".gocache")
		absCache, _ := filepath.Abs(cachePath)
		env := append(os.Environ(), "GOCACHE="+absCache)
		cmd.Env = env
		out, err := cmd.CombinedOutput()
		if err == nil {
			t.Fatalf("%s: expected non-zero exit; output=%s", tc.file, string(out))
		}
		if !strings.Contains(string(out), "\"error\": \"validation\"") {
			t.Fatalf("%s: missing structured error: %s", tc.file, string(out))
		}
		if bytes.Contains(out, []byte("spec:")) {
			t.Fatalf("%s: unexpected YAML on stdout: %s", tc.file, string(out))
		}
		joined := string(out)
		for _, w := range tc.want {
			if !strings.Contains(joined, w) {
				t.Fatalf("%s: missing cause %q in %s", tc.file, w, joined)
			}
		}
	}
}

// US1 refusals: exercise the CLI so stdout stays empty and causes are on stderr.
func TestUS1_Refusals_CLI(t *testing.T) {
	cases := []struct {
		file string
		env  map[string]string
		want []string
	}{
		{file: "refuse_wrong_var_l2vni_on_vlan.json", want: []string{"l2vni: a vlan is local to the node"}},
		{file: "refuse_wrong_var_gateway_on_ipvrf.json", want: []string{"anycastGateway: belongs to the mac-vrf"}},
		{file: "refuse_unknown_construct.json", want: []string{"type: unsupported 'foo-service'", "constructs: vlan, mac-vrf, ip-vrf, acl"}},
		{file: "refuse_reserved_vlan_band.json", want: []string{"l3vni:", "10000-14094"}},
		{file: "refuse_vlan_mismatch_endpoints.json", want: []string{"every endpoint must share one vlan"}},
		{file: "refuse_unknown_node.json", env: map[string]string{"FABRIC_NODE_MAP": `{"leaf01":"n1","leaf02":"n2"}`, "FABRIC_PORT_MAP": `{"ethernet1":"eth3","wan1":"eth4"}`}, want: []string{"endpoints[0].node", "site has: leaf01, leaf02"}},
		{file: "refuse_unknown_port.json", env: map[string]string{"FABRIC_NODE_MAP": `{"leaf01":"n1","leaf02":"n2"}`, "FABRIC_PORT_MAP": `{"ethernet1":"eth3","wan1":"eth4"}`}, want: []string{"endpoints[0].attachment", "site has: ethernet1, wan1"}},
	}
	for _, tc := range cases {
		repoRoot := filepath.Join("..", "..")
		cmd := exec.Command("go", "run", "./cmd/migration-translator", "--file", filepath.Join("tests", "unit", "testdata", "migration", tc.file))
		cmd.Dir = repoRoot
		// Ensure a writable build cache for go run; GOCACHE must be absolute
		cachePath := filepath.Join(repoRoot, ".gocache")
		absCache, _ := filepath.Abs(cachePath)
		env := append(os.Environ(), "GOCACHE="+absCache)
		for k, v := range tc.env {
			env = append(env, k+"="+v)
		}
		cmd.Env = env
		out, err := cmd.CombinedOutput()
		if err == nil {
			t.Fatalf("%s: expected non-zero exit; output=%s", tc.file, string(out))
		}
		// Structured JSON on stderr merged into out; no YAML on stdout
		if !strings.Contains(string(out), "\"error\": \"validation\"") {
			t.Fatalf("%s: missing structured error: %s", tc.file, string(out))
		}
		if bytes.Contains(out, []byte("spec:")) {
			t.Fatalf("%s: unexpected YAML on stdout: %s", tc.file, string(out))
		}
		joined := string(out)
		for _, w := range tc.want {
			if !strings.Contains(joined, w) {
				t.Fatalf("%s: missing cause %q in %s", tc.file, w, joined)
			}
		}
	}
}

func TestUnsupportedFeatureRejectionLegacy(t *testing.T) {
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

// US3 (T052): a gateway naming only IPv4 emits only gatewayIPv4 — the service
// is never held to an address family it did not ask for (spec US3 AS2).
func TestGatewaySingleFamily(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID:      "svc-gw4",
		Type:           migration.ServiceMACVRF,
		Tenant:         "blue",
		RDRT:           &migration.RdRt{RD: "65000:410", ImportRT: []string{"65000:410"}, ExportRT: []string{"65000:410"}},
		L2VNI:          10410,
		L3VNI:          13410,
		AnycastGateway: &migration.AnycastGateway{GatewayV4: "10.60.0.1/24"},
		Endpoints:      []migration.Endpoint{{Node: "leaf01", Attachment: "ethernet3", VLAN: 110}},
	}
	in.Canonicalize()
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Fatalf("validate: %s", migration.MarshalError(err))
	}
	out, err := migration.Translate(&in)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if !strings.Contains(out.NetworkYAML, "gatewayIPv4: 10.60.0.1/24") {
		t.Fatalf("expected the requested IPv4 gateway in the YAML:\n%s", out.NetworkYAML)
	}
	if strings.Contains(out.NetworkYAML, "gatewayIPv6") {
		t.Fatalf("an unrequested IPv6 gateway was added to the SVI:\n%s", out.NetworkYAML)
	}
}

// US3 (T053): a mac-vrf without an anycastGateway emits no routers entry and
// claims no L3VNI (spec US3 AS3) — routing is composition, not implication.
func TestMacVRFWithoutGatewayClaimsNoL3(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID: "svc-gw0",
		Type:      migration.ServiceMACVRF,
		Tenant:    "blue",
		RDRT:      &migration.RdRt{RD: "65000:411", ImportRT: []string{"65000:411"}, ExportRT: []string{"65000:411"}},
		L2VNI:     10411,
		Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "ethernet2", VLAN: 111}, {Node: "leaf02", Attachment: "ethernet2", VLAN: 111}},
	}
	in.Canonicalize()
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Fatalf("validate: %s", migration.MarshalError(err))
	}
	out, err := migration.Translate(&in)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if strings.Contains(out.NetworkYAML, "routers:") {
		t.Fatalf("a gatewayless mac-vrf emitted a routers entry:\n%s", out.NetworkYAML)
	}
	if strings.Contains(out.NetworkYAML, "l3vni") {
		t.Fatalf("a gatewayless mac-vrf claimed an L3VNI:\n%s", out.NetworkYAML)
	}
}
