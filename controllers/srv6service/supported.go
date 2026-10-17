// SPDX-License-Identifier: Apache-2.0
//
// Supported-variant check, rule C6 (T372/T373). The supported set is the
// srv6-supported key of the capability record (data-model.md §3): only a
// proven variant renders; anything else is a terminal UnsupportedVariant
// naming the supported ones.
//
// "steering" as a supported entry refers to spec.path being honoured for
// ip-vrf/vpn (contracts/fabricplan-srv6.md §3.2): a steered service needs
// both "ip-vrf/vpn" and "steering" proven. The refusal always names the
// construct/signalling variant.
package srv6service

import (
	"fmt"
	"strings"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/reasons"
)

// variantOf returns the construct/signalling variant name, defaulting the
// signalling exactly as the API documents (vpn for ip-vrf, evpn for mac-vrf).
func variantOf(svc *v1alpha1.SRv6Service) string {
	signalling := svc.Spec.Signalling
	if signalling == "" {
		if svc.Spec.Construct == v1alpha1.ConstructMACVRF {
			signalling = v1alpha1.SignallingEVPN
		} else {
			signalling = v1alpha1.SignallingVPN
		}
	}
	return svc.Spec.Construct + "/" + signalling
}

// steered reports whether the service pins a path (and therefore needs the
// steering recipe in addition to its construct/signalling variant).
func steered(svc *v1alpha1.SRv6Service) bool {
	return svc.Spec.Path.PreferredSpine != ""
}

// checkSupported enforces C6: the variant (and, when steered, steering) must
// be in the supported set. The refusal names the supported variants.
func checkSupported(svc *v1alpha1.SRv6Service, cap *Capability) *Refusal {
	variant := variantOf(svc)
	inSet := func(want string) bool { return contains(cap.Supported, want) }

	if !inSet(variant) {
		return &Refusal{
			Reason: reasons.ReasonUnsupportedVariant,
			Message: fmt.Sprintf("variant %s is not in the supported set %s",
				variant, formatSupported(cap.Supported)),
			Kind: refusalVariant,
		}
	}
	if steered(svc) && !inSet("steering") {
		return &Refusal{
			Reason: reasons.ReasonUnsupportedVariant,
			Message: fmt.Sprintf("variant %s is supported but steering (spec.path) is not: supported set %s",
				variant, formatSupported(cap.Supported)),
			Kind: refusalVariant,
		}
	}
	return nil
}

func formatSupported(supported []string) string {
	if len(supported) == 0 {
		return "(empty)"
	}
	return "[" + strings.Join(supported, ", ") + "]"
}
