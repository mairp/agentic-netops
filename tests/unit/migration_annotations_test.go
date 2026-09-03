package unit

import (
	"github.com/mairp/agentic-netops/pkg/migration"
	"strings"
	"testing"
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
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Fatalf("validate: %v", err)
	}
	bundle, err := migration.Translate(&in)
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	y := bundle.NetworkYAML
	for _, k := range []string{
		"agentic-netops.io/translator:",
		"agentic-netops.io/translator-version:",
		"agentic-netops.io/mapping-version:",
		"agentic-netops.io/migration-input-hash:",
		"agentic-netops.io/tenant:",
		"agentic-netops.io/service-type:",
	} {
		if !strings.Contains(y, k) {
			t.Fatalf("missing annotation key %s", k)
		}
	}
}
