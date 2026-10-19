package unit

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/pkg/migration"
)

// loadSrv6Fixture parses one strict testdata input into a single ServiceInput.
func loadSrv6Fixture(t *testing.T, name string) migration.ServiceInput {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "migration", name))
	if err != nil {
		t.Fatal(err)
	}
	inputs, err := migration.ParseStrictBatch(b)
	if err != nil {
		t.Fatalf("parse %s: %v", name, err)
	}
	if len(inputs) != 1 {
		t.Fatalf("%s: expected 1 input, got %d", name, len(inputs))
	}
	return inputs[0]
}

// validateCauses runs the all-or-nothing validator and returns the causes.
func validateCauses(t *testing.T, in migration.ServiceInput) []string {
	t.Helper()
	err := in.ValidateAllOrNothing(0, false)
	if err == nil {
		return nil
	}
	ve, ok := err.(*migration.ValidationError)
	if !ok {
		t.Fatalf("expected *migration.ValidationError, got %T", err)
	}
	return ve.Causes
}

// TestSrv6Validation_V1: an unsupported transport is named with its value.
func TestSrv6Validation_V1_UnsupportedTransport(t *testing.T) {
	in := loadSrv6Fixture(t, "srv6_v1_transport.json")
	want := "transport: unsupported 'mpls' (transports: vxlan, srv6)"
	if got := validateCauses(t, in); len(got) != 1 || got[0] != want {
		t.Fatalf("causes = %v, want exactly [%s]", got, want)
	}
}

// TestSrv6Validation_V2: srv6 carries ip-vrf and mac-vrf only.
func TestSrv6Validation_V2_Construct(t *testing.T) {
	in := loadSrv6Fixture(t, "srv6_v2_construct.json")
	want := "transport: srv6 applies to ip-vrf and mac-vrf only"
	if got := validateCauses(t, in); len(got) != 1 || got[0] != want {
		t.Fatalf("causes = %v, want exactly [%s]", got, want)
	}
}

// TestSrv6Validation_V3: the fabric allocates srv6 identifiers.
func TestSrv6Validation_V3_Identifiers(t *testing.T) {
	in := loadSrv6Fixture(t, "srv6_v3_identifiers.json")
	want := "srv6: identifiers are allocated by the fabric, not supplied"
	if got := validateCauses(t, in); len(got) != 1 || got[0] != want {
		t.Fatalf("causes = %v, want exactly [%s]", got, want)
	}
}

// TestSrv6Validation_V4: a bridged srv6 service is signalled with EVPN.
func TestSrv6Validation_V4_MacVRFSignalling(t *testing.T) {
	in := loadSrv6Fixture(t, "srv6_v4_macvpn.json")
	want := "signalling: mac-vrf over srv6 uses evpn"
	if got := validateCauses(t, in); len(got) != 1 || got[0] != want {
		t.Fatalf("causes = %v, want exactly [%s]", got, want)
	}
}

// TestSrv6Validation_V5: the srv6-only fields are refused on vxlan.
func TestSrv6Validation_V5_VxlanOnlyFields(t *testing.T) {
	in := loadSrv6Fixture(t, "srv6_v5_vxlan_spine.json")
	want := "preferredSpine: only valid with transport srv6"
	if got := validateCauses(t, in); len(got) != 1 || got[0] != want {
		t.Fatalf("causes = %v, want exactly [%s]", got, want)
	}
	// signalling alone gets its own cause.
	in2 := in
	in2.PreferredSpine = ""
	in2.Signalling = "vpn"
	want2 := "signalling: only valid with transport srv6"
	if got := validateCauses(t, in2); len(got) != 1 || got[0] != want2 {
		t.Fatalf("signalling causes = %v, want exactly [%s]", got, want2)
	}
}

// TestSrv6Validation_V6: exactly two attachments on distinct nodes.
func TestSrv6Validation_V6_Endpoints(t *testing.T) {
	in := loadSrv6Fixture(t, "srv6_v6_endpoints.json")
	want := "endpoints: an srv6 service joins exactly two attachments on distinct nodes"
	if got := validateCauses(t, in); len(got) != 1 || got[0] != want {
		t.Fatalf("causes = %v, want exactly [%s]", got, want)
	}
}

// TestSrv6Validation_V7: a preferred spine must be one of the site's spines.
func TestSrv6Validation_V7_UnknownSpine(t *testing.T) {
	t.Setenv("FABRIC_SPINE_NODES", "spine01,spine02")
	in := loadSrv6Fixture(t, "srv6_v7_spine.json")
	want := "preferredSpine: unknown 'spine99' (site has: spine01, spine02)"
	if got := validateCauses(t, in); len(got) != 1 || got[0] != want {
		t.Fatalf("causes = %v, want exactly [%s]", got, want)
	}
}

// TestSrv6Validation_V7_NoSpines: with no spine inventory configured, V7
// validates nothing — the same philosophy as the node/attachment checks.
func TestSrv6Validation_V7_NoSpineInventory(t *testing.T) {
	t.Setenv("FABRIC_SPINE_NODES", "")
	in := loadSrv6Fixture(t, "srv6_v7_spine.json")
	if got := validateCauses(t, in); len(got) != 0 {
		t.Fatalf("causes = %v, want none", got)
	}
}

// TestSrv6Validation_V8: a tePolicy claim keeps the refusal a tePolicy
// refusal; preferredSpine adds no cause of its own.
func TestSrv6Validation_V8_TEPolicy(t *testing.T) {
	t.Setenv("FABRIC_SPINE_NODES", "spine01,spine02")
	in := loadSrv6Fixture(t, "srv6_v8_tepolicy.json")
	got := validateCauses(t, in)
	if len(got) != 1 || got[0] != "unsupported: tePolicy" {
		t.Fatalf("causes = %v, want exactly [unsupported: tePolicy]", got)
	}
}

// TestSrv6Validation_NoIdentifiersClean: the identifiers are lifted over srv6 —
// an ip-vrf with no rdRt/l3vni and a mac-vrf with no l2vni validate clean.
func TestSrv6Validation_NoIdentifiersClean(t *testing.T) {
	ipVRF := loadSrv6Fixture(t, "srv6_ip_vrf_vpn.json")
	if got := validateCauses(t, ipVRF); len(got) != 0 {
		t.Fatalf("srv6 ip-vrf without identifiers: causes = %v, want none", got)
	}
	macVRF := loadSrv6Fixture(t, "srv6_mac_vrf_evpn.json")
	if got := validateCauses(t, macVRF); len(got) != 0 {
		t.Fatalf("srv6 mac-vrf without identifiers: causes = %v, want none", got)
	}
}

// TestSrv6Validation_ExistingFixturesUnchanged: with transport omitted every
// pre-existing fixture validates as before — no transport/srv6/signalling/
// preferredSpine cause may appear that was not there before.
func TestSrv6Validation_ExistingFixturesUnchanged(t *testing.T) {
	entries, err := os.ReadDir(filepath.Join("testdata", "migration"))
	if err != nil {
		t.Fatal(err)
	}
	srv6Prefixes := []string{"transport:", "srv6:", "signalling:", "preferredSpine:"}
	checked := 0
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".json") || strings.HasPrefix(name, "srv6_") {
			continue
		}
		b, err := os.ReadFile(filepath.Join("testdata", "migration", name))
		if err != nil {
			t.Fatal(err)
		}
		if strings.HasPrefix(strings.TrimSpace(string(b)), "[") {
			continue // a batch file, not a single-input fixture
		}
		var probe struct {
			Transport      string `json:"transport"`
			Signalling     string `json:"signalling"`
			PreferredSpine string `json:"preferredSpine"`
		}
		if err := json.Unmarshal(b, &probe); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if probe.Transport != "" || probe.Signalling != "" || probe.PreferredSpine != "" {
			t.Fatalf("%s: pre-existing fixture sets an srv6-era field", name)
		}
		inputs, err := migration.ParseStrictBatch(b)
		if err != nil {
			continue // strict-parse refusals (malformed/unknown fields) are unchanged
		}
		for _, in := range inputs {
			for _, cause := range validateCauses(t, in) {
				for _, p := range srv6Prefixes {
					if strings.HasPrefix(cause, p) {
						t.Fatalf("%s: unexpected srv6-era cause %q", name, cause)
					}
				}
			}
		}
		checked++
	}
	if checked == 0 {
		t.Fatal("no pre-existing fixtures checked")
	}
}

// TestSrv6Translation_StableYAML: rendering the same srv6 input twice yields
// byte-identical YAML (T452).
func TestSrv6Translation_StableYAML(t *testing.T) {
	t.Setenv("FABRIC_SPINE_NODES", "spine01,spine02")
	in := loadSrv6Fixture(t, "srv6_ip_vrf_vpn.json")
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Fatalf("validate: %s", migration.MarshalError(err))
	}
	first, err := migration.Translate(&in)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	second, err := migration.Translate(&in)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if first.NetworkYAML != second.NetworkYAML {
		t.Fatalf("srv6 YAML is not byte-identical across renders")
	}
	if first.Kind != "SRv6Service" || second.Kind != "SRv6Service" {
		t.Fatalf("kind = %q/%q, want SRv6Service", first.Kind, second.Kind)
	}
	if strings.Contains(first.NetworkYAML, "kind: Network") {
		t.Fatalf("srv6 input must never produce a Network:\n%s", first.NetworkYAML)
	}
}
