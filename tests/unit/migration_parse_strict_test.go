package unit

import (
	"github.com/mairp/agentic-netops/pkg/migration"
	"testing"
)

func TestParseStrictRejectsUnknown(t *testing.T) {
	json := `{"serviceId":"svcX","type":"VPLS","tenant":"A","rdRt":{"rd":"65000:1","importRT":["65000:1"],"exportRT":["65000:1"]},"l2vni":10001,"endpoints":[{"node":"leaf01","attachment":"c1","vlan":10},{"node":"leaf02","attachment":"c2","vlan":10}],"unknown":"field"}`
	if _, err := migration.ParseStrictBatch([]byte(json)); err == nil {
		t.Fatalf("expected error for unknown field")
	}
}

// FR-002: case/separator folding resolves equivalent spellings to the same construct.
// We assert that multiple spellings fold to the canonical construct names
// via Canonicalize (which applies typeKey internally).
func TestTypeKeyCaseFolding(t *testing.T) {
	ipvrfSpellings := []migration.ServiceType{"IP-VRF", "ip_vrf", "ipvrf", "Ip-Vrf"}
	for _, tt := range ipvrfSpellings {
		in := migration.ServiceInput{ServiceID: "svc", Type: tt}
		in.Canonicalize()
		if in.Type != migration.ServiceIPVRF {
			t.Fatalf("%s did not fold to ip-vrf (got %q)", tt, in.Type)
		}
	}

	macvrfSpellings := []migration.ServiceType{"MAC VRF", "macvrf", "Mac-Vrf", "mac-vrf"}
	for _, tt := range macvrfSpellings {
		in := migration.ServiceInput{ServiceID: "svc", Type: tt}
		in.Canonicalize()
		if in.Type != migration.ServiceMACVRF {
			t.Fatalf("%s did not fold to mac-vrf (got %q)", tt, in.Type)
		}
	}
}
