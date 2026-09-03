package unit

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/pkg/migration"
)

func TestCollisionFixture_DuplicateServiceId(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("testdata", "migration", "collision_duplicate.json"))
	if err != nil {
		t.Fatal(err)
	}
	inputs, err := migration.ParseStrictBatch(b)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	outs, err := migration.RenderBatch(inputs)
	if err == nil {
		t.Fatalf("expected collision error")
	}
	if len(outs) != 0 {
		t.Fatalf("expected no outputs on collision")
	}
	msg := migration.MarshalError(err)
	if !strings.Contains(msg, "duplicate serviceId") {
		t.Fatalf("missing duplicate cause: %s", msg)
	}
}
