// SPDX-License-Identifier: Apache-2.0
//
// Conflict checks, rules C4 and C7 plus the operator-named-VLAN pre-check
// (T366-T369). All are evaluated before any claim:
//
//   - C4: no attachment port may be held by another SRv6Service or by a
//     Network (network.kubenet.dev): terminal PortInUse naming the holder.
//   - C7: a second resource for the same tenant and the same attachments is
//     a terminal PortInUse naming the first resource.
//   - A mac-vrf's operator-named VLAN held by another resource is a terminal
//     VlanInUse naming the holder (the kuid reservation is the authority;
//     this pre-check names the holding resource, which is what the operator
//     can act on).
package srv6service

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/kubenet"
	"github.com/mairp/agentic-netops/pkg/reasons"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// attachmentKey is the canonical "node/port" identity of one attachment.
func attachmentKey(att v1alpha1.Attachment) string { return att.Node + "/" + att.Port }

// attachmentKeys returns the service's attachment keys, sorted.
func attachmentKeys(svc *v1alpha1.SRv6Service) []string {
	out := make([]string, 0, len(svc.Spec.Attachments))
	for _, att := range svc.Spec.Attachments {
		out = append(out, attachmentKey(att))
	}
	sort.Strings(out)
	return out
}

// sameAttachments reports whether two key lists are identical.
func sameAttachments(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// portsOf extracts the port names from attachment keys.
func portsOf(keys []string) []string {
	out := make([]string, 0, len(keys))
	for _, k := range keys {
		if i := strings.Index(k, "/"); i >= 0 {
			out = append(out, k[i+1:])
		}
	}
	sort.Strings(out)
	return out
}

// firstResource reports whether a is the first of the two resources: older
// creation timestamp, tie-broken by UID for objects created in the same
// timestamp resolution. Rule C7's holder is "the first resource" — a younger
// twin is the one refused, never the older one.
func firstResource(a, b *v1alpha1.SRv6Service) bool {
	if !a.CreationTimestamp.Equal(&b.CreationTimestamp) {
		return a.CreationTimestamp.Before(&b.CreationTimestamp)
	}
	return a.UID < b.UID
}

// isTerminalRefused reports whether the object's own Ready condition is a
// terminal refusal for its CURRENT generation. Such an object has claimed
// nothing and written nothing (the sample contract: "refused by name,
// nothing claimed, nothing written"), so it can hold no port and no service
// identity — live evidence 2026-10-16: a refused q9 twin held the
// attachments AGAINST the older Ready service and refused it.
func isTerminalRefused(svc *v1alpha1.SRv6Service) bool {
	for _, cond := range svc.Status.Conditions {
		if cond.Type != "Ready" {
			continue
		}
		if cond.ObservedGeneration != svc.Generation {
			return false // a stale condition must not grant or deny holding
		}
		switch cond.Reason {
		case reasons.ReasonInvalidSite, reasons.ReasonPortInUse, reasons.ReasonCapabilityMissing,
			reasons.ReasonUnsupportedVariant, reasons.ReasonPoolExhausted, reasons.ReasonDataPathUnverifiable,
			reasons.ReasonVlanInUse:
			return cond.Status == metav1.ConditionFalse
		}
		return false
	}
	return false
}

// checkConflicts enforces C4, C7 and the VLAN pre-check against the other
// resources in the service's namespace. Returns ONE refusal (T396).
func checkConflicts(ctx context.Context, c client.Client, svc *v1alpha1.SRv6Service) *Refusal {
	keys := attachmentKeys(svc)
	ports := portsOf(keys)

	var services v1alpha1.SRv6ServiceList
	if err := c.List(ctx, &services, client.InNamespace(svc.Namespace)); err != nil {
		return nil // the list failing must not fabricate a conflict; the caller surfaces transient errors separately
	}
	for i := range services.Items {
		other := &services.Items[i]
		if other.UID == svc.UID {
			continue
		}
		// A terminally refused object holds nothing, and a younger object
		// never holds against the first resource: skip it on both counts.
		if isTerminalRefused(other) || !firstResource(other, svc) {
			continue
		}
		otherKeys := attachmentKeys(other)
		// C7: same tenant AND same attachments -> the first resource holds
		// the service identity.
		if other.Spec.Tenant == svc.Spec.Tenant && sameAttachments(keys, otherKeys) {
			return &Refusal{
				Reason: reasons.ReasonPortInUse,
				Message: fmt.Sprintf("attachments %s for tenant %q already held by SRv6Service %q",
					strings.Join(keys, ", "), svc.Spec.Tenant, other.Name),
				Kind: refusalPort,
			}
		}
		// C4: any shared attachment port is held by the other service.
		for _, p := range portsOf(otherKeys) {
			if contains(ports, p) {
				return &Refusal{
					Reason: reasons.ReasonPortInUse,
					Message: fmt.Sprintf("port %s is already held by SRv6Service %q (this service wants %s)",
						p, other.Name, strings.Join(ports, ", ")),
					Kind: refusalPort,
				}
			}
		}
		// Operator-named VLAN of a mac-vrf held by another resource.
		if svc.Spec.VLAN != nil && other.Spec.VLAN != nil && *svc.Spec.VLAN == *other.Spec.VLAN {
			return &Refusal{
				Reason: reasons.ReasonVlanInUse,
				Message: fmt.Sprintf("vlan %d is already named by SRv6Service %q",
					*svc.Spec.VLAN, other.Name),
				Kind: refusalVlan,
			}
		}
	}

	// C4 against Networks: a Network attachment names the logical port in
	// .attachment (pkg/kubenet.NetworkAttachment).
	var networks kubenet.NetworkList
	if err := c.List(ctx, &networks, client.InNamespace(svc.Namespace)); err != nil {
		return nil
	}
	for i := range networks.Items {
		net := &networks.Items[i]
		for _, na := range net.Attachments() {
			if contains(ports, na.Attachment) {
				return &Refusal{
					Reason: reasons.ReasonPortInUse,
					Message: fmt.Sprintf("port %s is already held by Network %q (this service wants %s)",
						na.Attachment, net.Name, strings.Join(ports, ", ")),
					Kind: refusalPort,
				}
			}
		}
	}
	return nil
}
