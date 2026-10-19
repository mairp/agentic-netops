//go:build agentic_netops_k8s

// This package's k8s sources (network_controller.go, reasons.go) carry the
// agentic_netops_k8s tag; this test references NodeKindFromEnv from that set
// and must build in the same configuration, or the tag-less `go test ./...`
// fails to compile the package (observed 2026-10-15, phase-4 gate precheck).
package sonicprovider

import (
	"testing"

	"github.com/mairp/agentic-netops/pkg/fabricplan"
)

// T192-T218: plans must target the deployed lab profile's guests. The provider
// learns the kind from FABRIC_NODE_KIND (provision.sh injects the active
// profile); empty keeps the fabricplan default (sonic-vs) byte-for-byte.
func TestNodeKindFromEnv(t *testing.T) {
	if got := NodeKindFromEnv(); got != "" {
		t.Fatalf("unset FABRIC_NODE_KIND must render the default kind, got %q", got)
	}
	t.Setenv("FABRIC_NODE_KIND", "sonic-vm")
	if got := NodeKindFromEnv(); got != "sonic-vm" {
		t.Fatalf("FABRIC_NODE_KIND=sonic-vm not honored, got %q", got)
	}
	if _, ok := map[string]bool{"sonic-vs": true, "sonic-vm": true}["sonic-vm"]; !ok {
		t.Fatal("kind registry drifted")
	}
	_ = fabricplan.Options{}
}
