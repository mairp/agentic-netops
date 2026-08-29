package unit

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Ensure the CLI rejects a validation failure (unsupported TE) with structured JSON and no YAML outputs.
func TestMigrationCLI_RejectsUnsupportedTE_NoOutput(t *testing.T) {
	cmd := exec.Command("go", "run", "./cmd/migration-translator", "--file", "tests/unit/testdata/migration/unsupported_te.json")
	cmd.Dir = filepath.Join("..", "..")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("expected non-zero exit; output=%s", string(out))
	}
	if !strings.Contains(string(out), "\"error\": \"validation\"") {
		t.Fatalf("missing structured validation error: %s", string(out))
	}
	if strings.Contains(string(out), "spec:") {
		t.Fatalf("unexpected YAML output on validation failure: %s", string(out))
	}
}
