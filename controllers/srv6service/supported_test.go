// SPDX-License-Identifier: Apache-2.0
//
// Supported-variant tests, T372 (rule C6): only a variant in the capability
// record's srv6-supported set renders — anything else is a terminal
// UnsupportedVariant naming the supported set. "steering" counts as part of
// the set: a steered service needs it proven on top of its variant.
package srv6service

import (
	"strings"
	"testing"

	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/reasons"
)

// capsWith builds a proven Capability record with the given variants.
func capsWith(supported ...string) *Capability {
	return &Capability{Found: true, SAISRV6: true, Supported: supported}
}

// TestUnsupportedVariantNamesTheSupportedSet is T372.
func TestUnsupportedVariantNamesTheSupportedSet(t *testing.T) {
	cap := capsWith("ip-vrf/vpn", "steering")

	t.Run("mac-vrf-evpn", func(t *testing.T) {
		svc := testService("c6-mac", "c6-1")
		svc.Spec.Construct = agenticnetopsv1alpha1.ConstructMACVRF
		svc.Spec.Signalling = agenticnetopsv1alpha1.SignallingEVPN
		ref := checkSupported(svc, cap)
		if ref == nil {
			t.Fatal("mac-vrf/evpn accepted, want UnsupportedVariant")
		}
		if ref.Reason != reasons.ReasonUnsupportedVariant {
			t.Fatalf("reason = %q, want %q", ref.Reason, reasons.ReasonUnsupportedVariant)
		}
		if !ref.Terminal() {
			t.Error("UnsupportedVariant must be terminal")
		}
		for _, want := range []string{"mac-vrf/evpn", "supported set", "ip-vrf/vpn", "steering"} {
			if !strings.Contains(ref.Message, want) {
				t.Errorf("message %q must name %q", ref.Message, want)
			}
		}
	})

	t.Run("ip-vrf-evpn", func(t *testing.T) {
		svc := testService("c6-evpn", "c6-2")
		svc.Spec.Signalling = agenticnetopsv1alpha1.SignallingEVPN
		ref := checkSupported(svc, cap)
		if ref == nil || ref.Reason != reasons.ReasonUnsupportedVariant {
			t.Fatalf("ip-vrf/evpn refusal = %+v, want UnsupportedVariant", ref)
		}
		if !strings.Contains(ref.Message, "ip-vrf/evpn") {
			t.Errorf("message %q must name the variant", ref.Message)
		}
	})

	t.Run("steered-needs-steering-proven", func(t *testing.T) {
		svc := testService("c6-steered", "c6-3") // preferred spine set → steered
		ref := checkSupported(svc, capsWith("ip-vrf/vpn"))
		if ref == nil || ref.Reason != reasons.ReasonUnsupportedVariant {
			t.Fatalf("steered refusal = %+v, want UnsupportedVariant", ref)
		}
		for _, want := range []string{"ip-vrf/vpn", "steering (spec.path)", "supported set"} {
			if !strings.Contains(ref.Message, want) {
				t.Errorf("message %q must name %q", ref.Message, want)
			}
		}
	})

	t.Run("supported-set-passes", func(t *testing.T) {
		// The proven pair accepts both the plain and the steered shape.
		if ref := checkSupported(testService("c6-ok", "c6-4"), cap); ref != nil {
			t.Fatalf("steered ip-vrf/vpn refused: %s", ref.Message)
		}
		plain := testService("c6-ok2", "c6-5")
		plain.Spec.Path.PreferredSpine = ""
		if ref := checkSupported(plain, capsWith("ip-vrf/vpn")); ref != nil {
			t.Fatalf("unsteered ip-vrf/vpn refused: %s", ref.Message)
		}
		// The signalling default: an empty signalling on ip-vrf reads vpn.
		blank := testService("c6-ok3", "c6-6")
		blank.Spec.Signalling = ""
		if variantOf(blank) != "ip-vrf/vpn" {
			t.Errorf("variantOf(blank signalling) = %q, want ip-vrf/vpn", variantOf(blank))
		}
	})
}
