package unit

import (
	"bytes"
	"encoding/json"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mairp/ainetops/pkg/migration"
)

// Note: Some environments do not build the CLI during unit tests; we keep a smoke test
// that simply checks the binary path exists when built. Core behavior is validated via the library.
func TestMigrationCLI_StructuredUnknownField(t *testing.T) {
	bad := `{"serviceId":"svcX","type":"VPLS","tenant":"A","rdRt":{"rd":"65000:1","importRT":["65000:1"],"exportRT":["65000:1"]},"l2vni":10001,"endpoints":[{"node":"leaf01","attachment":"c1","vlan":10},{"node":"leaf02","attachment":"c2","vlan":10}],"unknown":"field"}`
	_, err := migration.ParseStrictBatch([]byte(bad))
	if err == nil { t.Fatalf("expected parse error due to unknown field") }
	msg := migration.MarshalError(err)
	// Ensure structured JSON with causes and the unknown field message.
	var m map[string]any
	if json.Unmarshal([]byte(msg), &m) != nil { t.Fatalf("not JSON: %s", msg) }
	if m["error"] != "validation" { t.Fatalf("missing error key: %v", m) }
	causes, ok := m["causes"].([]any)
	if !ok || len(causes) == 0 { t.Fatalf("missing causes: %v", m) }
	joined := msg
	if !strings.Contains(joined, "unknown field") { t.Fatalf("expected unknown field in causes: %s", msg) }
}

func TestMigrationCLI_ExecutesAndRejectsUnknown(t *testing.T) {
	// Try to run the CLI with go run so the test does not depend on a prebuilt binary.
	bad := `{"serviceId":"svcX","type":"VPLS","tenant":"A","rdRt":{"rd":"65000:1","importRT":["65000:1"],"exportRT":["65000:1"]},"l2vni":10001,"endpoints":[{"node":"leaf01","attachment":"c1","vlan":10},{"node":"leaf02","attachment":"c2","vlan":10}],"unknown":"field"}`
	cmd := exec.Command("go", "run", "./cmd/migration-translator")
	cmd.Dir = filepath.Join("..", "..")
	cmd.Stdin = bytes.NewBufferString(bad)
	out, err := cmd.CombinedOutput()
	if err == nil { t.Fatalf("expected non-zero exit; output=%s", string(out)) }
	// Expect structured JSON on stderr; CombinedOutput merges streams; check JSON presence and absence of YAML spec.
	if !strings.Contains(string(out), "\"error\": \"validation\"") { t.Fatalf("missing structured error: %s", string(out)) }
	if strings.Contains(string(out), "spec:") { t.Fatalf("unexpected YAML output on parse failure: %s", string(out)) }
}
