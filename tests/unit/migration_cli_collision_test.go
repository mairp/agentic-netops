package unit

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Ensure the CLI rejects duplicate serviceId collision with structured JSON and no YAML outputs.
func TestMigrationCLI_RejectsCollision_NoOutput(t *testing.T) {
	cmd := exec.Command("go", "run", "./cmd/migration-translator", "--file", "tests/unit/testdata/migration/collision_duplicate.json")
	cmd.Dir = filepath.Join("..", "..")
	out, err := cmd.CombinedOutput()
	if err == nil {
		// some environments may not have go toolchain; we still assert behavior on stderr/stdout content
		// but keep the failure to maintain strong signal in CI
		t.Fatalf("expected non-zero exit; output=%s", string(out))
	}
	if !strings.Contains(string(out), "\"error\": \"validation\"") {
		t.Fatalf("missing structured validation error: %s", string(out))
	}
	if !strings.Contains(string(out), "duplicate serviceId") {
		t.Fatalf("missing duplicate cause in CLI output: %s", string(out))
	}
	if strings.Contains(string(out), "spec:") {
		t.Fatalf("unexpected YAML output on validation failure: %s", string(out))
	}
}
