package unit

import (
	"testing"
	"github.com/mairp/ainetops/pkg/migration"
)

func TestParseStrictRejectsUnknown(t *testing.T) {
	json := `{"serviceId":"svcX","type":"VPLS","tenant":"A","rdRt":{"rd":"65000:1","importRT":["65000:1"],"exportRT":["65000:1"]},"l2vni":10001,"endpoints":[{"node":"leaf01","attachment":"c1","vlan":10},{"node":"leaf02","attachment":"c2","vlan":10}],"unknown":"field"}`
	if _, err := migration.ParseStrictBatch([]byte(json)); err == nil {
		t.Fatalf("expected error for unknown field")
	}
}
