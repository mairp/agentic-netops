package unit

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mairp/ainetops/pkg/migration"
)

func TestGolden_VPLS(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("testdata", "migration", "supported_vpls.json"))
	if err != nil { t.Fatal(err) }
	inputs, err := migration.ParseStrictBatch(b)
	if err != nil { t.Fatalf("parse: %v", err) }
	outs, err := migration.RenderBatch(inputs)
	if err != nil { t.Fatalf("render: %s", migration.MarshalError(err)) }
	if len(outs) != 1 { t.Fatalf("expected 1 doc, got %d", len(outs)) }
	// Compare only the spec subtree for stability.
	spec := extractYAMLSnippet(outs[0], "spec:")
	gold, _ := os.ReadFile(filepath.Join("testdata", "migration", "supported_vpls.spec.golden.yaml"))
	if strings.TrimSpace(spec) != strings.TrimSpace(string(gold)) {
		// optional: write a diff for debugging
		_ = os.WriteFile(filepath.Join(os.TempDir(), "vpls.spec.actual.yaml"), []byte(spec), 0o644)
		t.Fatalf("golden mismatch for VPLS spec")
	}
}

func TestGolden_L3VPN(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("testdata", "migration", "supported_l3vpn.json"))
	if err != nil { t.Fatal(err) }
	inputs, err := migration.ParseStrictBatch(b)
	if err != nil { t.Fatalf("parse: %v", err) }
	outs, err := migration.RenderBatch(inputs)
	if err != nil { t.Fatalf("render: %s", migration.MarshalError(err)) }
	if len(outs) != 1 { t.Fatalf("expected 1 doc, got %d", len(outs)) }
	spec := extractYAMLSnippet(outs[0], "spec:")
	gold, _ := os.ReadFile(filepath.Join("testdata", "migration", "supported_l3vpn.spec.golden.yaml"))
	if strings.TrimSpace(spec) != strings.TrimSpace(string(gold)) {
		_ = os.WriteFile(filepath.Join(os.TempDir(), "l3vpn.spec.actual.yaml"), []byte(spec), 0o644)
		t.Fatalf("golden mismatch for L3VPN spec")
	}
}

func TestGolden_VPWS_OptIn(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("testdata", "migration", "supported_vpws_optin.json"))
	if err != nil { t.Fatal(err) }
	inputs, err := migration.ParseStrictBatch(b)
	if err != nil { t.Fatalf("parse: %v", err) }
	outs, err := migration.RenderBatch(inputs)
	if err != nil { t.Fatalf("render: %s", migration.MarshalError(err)) }
	if len(outs) != 1 { t.Fatalf("expected 1 doc, got %d", len(outs)) }
	spec := extractYAMLSnippet(outs[0], "spec:")
	gold, _ := os.ReadFile(filepath.Join("testdata", "migration", "supported_vpws.spec.golden.yaml"))
	if strings.TrimSpace(spec) != strings.TrimSpace(string(gold)) {
		_ = os.WriteFile(filepath.Join(os.TempDir(), "vpws.spec.actual.yaml"), []byte(spec), 0o644)
		t.Fatalf("golden mismatch for VPWS spec")
	}
}

func TestReject_UnsupportedTE(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("testdata", "migration", "unsupported_te.json"))
	if err != nil { t.Fatal(err) }
	inputs, err := migration.ParseStrictBatch(b)
	if err != nil { t.Fatalf("parse: %v", err) }
	outs, err := migration.RenderBatch(inputs)
	if err == nil { t.Fatalf("expected error for unsupported TE policy") }
	if len(outs) != 0 { t.Fatalf("expected no outputs on failure") }
}

func TestIRB_Golden(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("testdata", "migration", "supported_irb.json"))
	if err != nil { t.Fatal(err) }
	inputs, err := migration.ParseStrictBatch(b)
	if err != nil { t.Fatalf("parse: %v", err) }
	outs, err := migration.RenderBatch(inputs)
	if err != nil { t.Fatalf("render: %s", migration.MarshalError(err)) }
	if len(outs) != 1 { t.Fatalf("expected 1 doc, got %d", len(outs)) }
	spec := extractYAMLSnippet(outs[0], "spec:")
	gold, _ := os.ReadFile(filepath.Join("testdata", "migration", "supported_irb.spec.golden.yaml"))
	if strings.TrimSpace(spec) != strings.TrimSpace(string(gold)) {
		_ = os.WriteFile(filepath.Join(os.TempDir(), "irb.spec.actual.yaml"), []byte(spec), 0o644)
		t.Fatalf("golden mismatch for IRB spec")
	}
}

func TestReject_MalformedUnknownField(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("testdata", "migration", "malformed_unknown_field.json"))
	if err != nil { t.Fatal(err) }
	if _, err := migration.ParseStrictBatch(b); err == nil {
		t.Fatalf("expected parse error due to unknown field")
	}
}

// extractYAMLSnippet returns the YAML starting at the given key name to EOF.
func extractYAMLSnippet(doc, start string) string {
	idx := strings.Index(doc, start)
	if idx < 0 { return "" }
	return doc[idx:]
}
