package unit

import (
	"strings"
	"testing"

	"github.com/mairp/ainetops/pkg/migration"
)

func TestReject_MissingEndpoints_VPLS(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID: "noep-vpls",
		Type:      migration.ServiceVPLS,
		Tenant:    "T",
		RDRT:      &migration.RdRt{RD: "65000:101", ImportRT: []string{"65000:101"}, ExportRT: []string{"65000:101"}},
		L2VNI:     10101,
		Endpoints: []migration.Endpoint{},
	}
	outs, err := migration.RenderBatch([]migration.ServiceInput{in})
	if err == nil {
		t.Fatalf("expected error for missing endpoints (VPLS)")
	}
	if len(outs) != 0 {
		t.Fatalf("expected no outputs on failure")
	}
	msg := migration.MarshalError(err)
	if !strings.Contains(msg, "endpoints:") {
		t.Fatalf("expected endpoints cause, got: %s", msg)
	}
}

func TestReject_MissingEndpoints_L3VPN(t *testing.T) {
	in := migration.ServiceInput{
		ServiceID: "noep-l3",
		Type:      migration.ServiceL3VPN,
		Tenant:    "T",
		RDRT:      &migration.RdRt{RD: "65000:102", ImportRT: []string{"65000:102"}, ExportRT: []string{"65000:102"}},
		L3VNI:     20102,
		AF:        &migration.AddressFamilies{IPv4Prefixes: []string{"10.1.2.0/24"}},
		Endpoints: []migration.Endpoint{},
	}
	outs, err := migration.RenderBatch([]migration.ServiceInput{in})
	if err == nil {
		t.Fatalf("expected error for missing endpoints (L3VPN)")
	}
	if len(outs) != 0 {
		t.Fatalf("expected no outputs on failure")
	}
	msg := migration.MarshalError(err)
	if !strings.Contains(msg, "L3VPN requires >=1 endpoint") {
		t.Fatalf("expected L3VPN endpoints cause, got: %s", msg)
	}
}
