package unit

import (
	"testing"

	"github.com/mairp/agentic-netops/pkg/compat"
)

func TestCompat_FullValidateContractsAndPins(t *testing.T) {
	set := compat.Set{
		SonicImage:          "sha256:deadbeef",
		OpenConfigCommit:    "abcdef1",
		SonicNativeCommit:   "1234567",
		MappingVersion:      "v1",
		UpstreamAPIVersions: map[string]string{"sdc": "v0.31.0"},
	}
	labels := map[string]string{"agentic-netops.dev/topology-label-contract": "v1", "agentic-netops.dev/telemetry-label-contract": "v1"}
	if err := compat.FullValidate(set, labels, map[string]bool{"sai.srv6": true}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}
