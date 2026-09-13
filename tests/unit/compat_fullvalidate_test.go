// SPDX-License-Identifier: Apache-2.0
package unit

import (
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/pkg/compat"
)

func srlinuxPinSet() compat.Set {
	return compat.Set{
		SRLinuxImage:        "ghcr.io/nokia/srlinux@sha256:0096fe3ebcafabb7253492e2060425fe027a168e0e066766d1e85efbb0b48be8",
		SRLinuxYANG:         "v26.7.2",
		MappingVersion:      "v1",
		UpstreamAPIVersions: map[string]string{"sdc": "v0.31.0", "kubenet": "bae1c48", "kuid": "7528e81"},
	}
}

func contractLabels(srv6 string) map[string]string {
	return map[string]string{
		"agentic-netops.dev/topology-label-contract":  "v1",
		"agentic-netops.dev/telemetry-label-contract": "v1",
		"agentic-netops.dev/cap.sai.srv6":             srv6,
	}
}

func TestCompat_FullValidateContractsAndPins(t *testing.T) {
	if err := compat.FullValidate(srlinuxPinSet(), contractLabels("true"), map[string]bool{compat.CapabilitySRv6: true}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// FR-009: this site declares SRv6 absent (the SR Linux 7220 container has no
// SRv6 data plane). A Network needs nothing of the sort, so it must reconcile —
// the capability gate is not a blanket veto.
func TestCompat_NetworkPassesWithoutSRv6(t *testing.T) {
	discovered := map[string]bool{compat.CapabilitySRv6: false}
	if err := compat.FullValidate(srlinuxPinSet(), contractLabels("false"), discovered); err != nil {
		t.Fatalf("a Network was blocked on a capability it does not need: %v", err)
	}
}

// ...and the one object that does need it says so, and is refused by name.
func TestCompat_SRv6ServiceIsRefusedWithoutTheCapability(t *testing.T) {
	discovered := map[string]bool{compat.CapabilitySRv6: false}
	err := compat.FullValidate(srlinuxPinSet(), contractLabels("false"), discovered, compat.CapabilitySRv6)
	if err == nil {
		t.Fatal("an SRv6Service passed validation on a site with no SRv6 data plane")
	}
	if got := compat.ReasonFor(err); got != "CapabilityMissing" {
		t.Errorf("reason is %q, want CapabilityMissing", got)
	}
	if !strings.Contains(err.Error(), compat.CapabilitySRv6) {
		t.Errorf("the refusal does not name the missing capability: %v", err)
	}
}

func TestCompat_IncompletePinsAreSchemaMismatch(t *testing.T) {
	for name, mutate := range map[string]func(*compat.Set){
		"no image":                            func(s *compat.Set) { s.SRLinuxImage = "" },
		"no yang":                             func(s *compat.Set) { s.SRLinuxYANG = "" },
		"yang is a commit SHA, not a release": func(s *compat.Set) { s.SRLinuxYANG = "0096fe3" },
		"no mapping":                          func(s *compat.Set) { s.MappingVersion = "" },
	} {
		set := srlinuxPinSet()
		mutate(&set)
		err := compat.FullValidate(set, contractLabels("false"), map[string]bool{})
		if err == nil {
			t.Errorf("%s: validation passed", name)
			continue
		}
		if got := compat.ReasonFor(err); got != "SchemaMismatch" {
			t.Errorf("%s: reason is %q, want SchemaMismatch", name, got)
		}
	}
}

// The ConfigMap keys provision writes are the ones the validators read back.
func TestCompat_SitePinKeysAreTheSRLinuxOnes(t *testing.T) {
	for _, short := range []string{"srlinux-image", "srlinux-yang", "mapping-version", "cap-sai-srv6"} {
		if _, ok := compat.AnnotationFor(short); !ok {
			t.Errorf("fabric-compat-pins key %q maps to no annotation", short)
		}
	}
	for _, gone := range []string{"sonic-image", "sonic-native-commit", "openconfig-commit"} {
		if name, ok := compat.AnnotationFor(gone); ok {
			t.Errorf("SONiC pin key %q still resolves to %q", gone, name)
		}
	}
	ann := map[string]string{
		"agentic-netops.dev/srlinux-image": "ghcr.io/nokia/srlinux@sha256:0096",
		"agentic-netops.dev/srlinux-yang":  "v26.7.2",
	}
	set := compat.FromAnnotations(ann)
	if set.SRLinuxImage == "" || set.SRLinuxYANG != "v26.7.2" {
		t.Errorf("FromAnnotations did not read the SR Linux pins: %+v", set)
	}
}
