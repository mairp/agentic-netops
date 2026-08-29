package unit

import (
	"strings"
	"testing"
	"github.com/mairp/ainetops/pkg/migration"
)

func TestAnnotationsPresent(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID: "svcA",
		Type:      migration.ServiceVPLS,
		Tenant:    "TenA",
		RDRT:      &migration.RdRt{RD: "65000:1", ImportRT: []string{"65000:1"}, ExportRT: []string{"65000:1"}},
		L2VNI:     10001,
		Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "c1", VLAN: 10}, {Node: "leaf02", Attachment: "c2", VLAN: 10}},
	}
	if err := in.ValidateAllOrNothing(0, false); err != nil { t.Fatalf("validate: %v", err) }
	bundle, err := migration.Translate(&in)
	if err != nil { t.Fatalf("translate: %v", err) }
	y := bundle.NetworkYAML
	for _, k := range []string{
		"ainetops.io/translator:",
		"ainetops.io/translator-version:",
		"ainetops.io/mapping-version:",
		"ainetops.io/migration-input-hash:",
		"ainetops.io/tenant:",
		"ainetops.io/service-type:",
	} {
		if !strings.Contains(y, k) {
			t.Fatalf("missing annotation key %s", k)
		}
	}
}
