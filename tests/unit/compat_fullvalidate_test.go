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
	if err := compat.FullValidate(set, labels, compat.KindNetwork, map[string]bool{"sai.srv6": true}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// T016 — capability scoping (FR-007; plan 1-09): the SRv6 capability is
// required for SRv6Service objects only. A Network validates even when the
// site reports cap-sai-srv6=false (that is the honest state of every lab
// until feature 004 proves SRv6); an SRv6Service does not.
func TestCompat_FullValidateSRv6CapabilityScoping(t *testing.T) {
	set := compat.Set{
		SonicImage:          "sha256:deadbeef",
		OpenConfigCommit:    "abcdef1",
		SonicNativeCommit:   "1234567",
		MappingVersion:      "v1",
		UpstreamAPIVersions: map[string]string{"sdc": "v0.31.0"},
	}
	labels := map[string]string{"agentic-netops.dev/topology-label-contract": "v1", "agentic-netops.dev/telemetry-label-contract": "v1"}

	t.Run("network validates with cap-sai-srv6 false", func(t *testing.T) {
		if err := compat.FullValidate(set, labels, compat.KindNetwork, map[string]bool{"sai.srv6": false}); err != nil {
			t.Fatalf("Network must not require the SRv6 capability, got: %v", err)
		}
	})
	t.Run("srv6 service does not validate with cap-sai-srv6 false", func(t *testing.T) {
		err := compat.FullValidate(set, labels, compat.KindSRv6Service, map[string]bool{"sai.srv6": false})
		if err == nil {
			t.Fatal("SRv6Service must require the SRv6 capability; validation passed without it")
		}
		if compat.ReasonFor(err) != "CapabilityMissing" {
			t.Fatalf("expected CapabilityMissing, got: %v", err)
		}
	})
	t.Run("srv6 service validates when the capability is present", func(t *testing.T) {
		if err := compat.FullValidate(set, labels, compat.KindSRv6Service, map[string]bool{"sai.srv6": true}); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	})
}
