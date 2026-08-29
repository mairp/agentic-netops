package unit

import (
	"strings"
	"testing"
	"github.com/mairp/ainetops/pkg/migration"
)

func goodVPLS() migration.ServiceInput {
	return migration.ServiceInput{
		ServiceID: "svcVPLS",
		Type:      migration.ServiceVPLS,
		Tenant:    "T",
		RDRT:      &migration.RdRt{RD: "65000:1", ImportRT: []string{"65000:1"}, ExportRT: []string{"65000:1"}},
		L2VNI:     10001,
		Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "c1", VLAN: 10}, {Node: "leaf02", Attachment: "c2", VLAN: 10}},
	}
}

func TestBatchAllOrNothing(t *testing.T) {
	ok := goodVPLS()
	bad := ok
	bad.ServiceID = "dup"
	ok.ServiceID = "dup"
	outs, err := migration.RenderBatch([]migration.ServiceInput{ok, bad})
	if err == nil { t.Fatalf("expected error for duplicate serviceId") }
	if len(outs) != 0 { t.Fatalf("expected no outputs on failure") }
	msg := migration.MarshalError(err)
	if !strings.Contains(msg, "duplicate serviceId") {
		t.Fatalf("expected duplicate cause, got: %s", msg)
	}
}

func TestBatchAllOrNothing_MixedUnsupported(t *testing.T) {
	ok := goodVPLS()
	bad := goodVPLS()
	bad.ServiceID = "bad"
	bad.Unsupported.TEPolicy = true
	outs, err := migration.RenderBatch([]migration.ServiceInput{ok, bad})
	if err == nil { t.Fatalf("expected error for unsupported TE policy in batch") }
	if len(outs) != 0 { t.Fatalf("expected no outputs on mixed failure") }
	msg := migration.MarshalError(err)
	if !strings.Contains(msg, "unsupported: tePolicy") { t.Fatalf("missing unsupported cause: %s", msg) }
}
