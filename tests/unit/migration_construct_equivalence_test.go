package unit

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/mairp/agentic-netops/pkg/migration"
)

// T058 — Brownfield/construct spec-block byte identity.
// For each legacy input, assert the emitted spec: block is byte-identical to
// the same service expressed with construct names. This guards against
// accidental render drift masked by both goldens moving together.
func TestConstructLegacyEquivalence(t *testing.T) {
	cases := []struct{
		legacy string
		construct string
	}{
		{"supported_vpls.json", "construct_macvrf_equiv_svc1.json"},
		{"supported_vpws_optin.json", "construct_macvrf_equiv_svc3.json"},
		{"supported_l3vpn.json", "construct_ipvrf_equiv_svc2.json"},
		{"supported_irb.json", "construct_macvrf_gateway_equiv_irb1.json"},
	}
	for _, tc := range cases {
		// Read and translate the legacy input
		b1, err := os.ReadFile(filepath.Join("testdata", "migration", tc.legacy))
		if err != nil { t.Fatal(err) }
		in1, err := migration.ParseStrictBatch(b1)
		if err != nil { t.Fatalf("parse legacy %s: %v", tc.legacy, err) }
		out1, err := migration.RenderBatch(in1)
		if err != nil { t.Fatalf("render legacy %s: %s", tc.legacy, migration.MarshalError(err)) }
		if len(out1) != 1 { t.Fatalf("%s: expected 1 doc, got %d", tc.legacy, len(out1)) }
		spec1 := extractYAMLSnippet(out1[0], "spec:")

		// Read and translate the construct input
		b2, err := os.ReadFile(filepath.Join("testdata", "migration", tc.construct))
		if err != nil { t.Fatal(err) }
		in2, err := migration.ParseStrictBatch(b2)
		if err != nil { t.Fatalf("parse construct %s: %v", tc.construct, err) }
		out2, err := migration.RenderBatch(in2)
		if err != nil { t.Fatalf("render construct %s: %s", tc.construct, migration.MarshalError(err)) }
		if len(out2) != 1 { t.Fatalf("%s: expected 1 doc, got %d", tc.construct, len(out2)) }
		spec2 := extractYAMLSnippet(out2[0], "spec:")

		if spec1 != spec2 {
			_ = os.WriteFile(filepath.Join(os.TempDir(), tc.legacy+".spec.actual.yaml"), []byte(spec1), 0o644)
			_ = os.WriteFile(filepath.Join(os.TempDir(), tc.construct+".spec.actual.yaml"), []byte(spec2), 0o644)
			t.Fatalf("spec mismatch for %s vs %s", tc.legacy, tc.construct)
		}
	}
}
