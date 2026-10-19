// SPDX-License-Identifier: Apache-2.0
//
// Capability record checks, rules C5 and C8 (T370/T371). Both read the
// fabric-compat-pins ConfigMap UNCACHED (the same rule pkg/compat/pins.go
// documents: a broken shared ConfigMap informer must not be able to starve
// the decision), and both are terminal:
//
//   - C5: cap-sai-srv6 must be exactly "true". False, absent or an
//     unreadable/missing record each give a terminal CapabilityMissing, and
//     nothing has been claimed at this point.
//   - C8: every attachment ("node/port") must be listed in the record's
//     srv6-probe-attachments key; otherwise the data path could never be
//     verified, so the request is refused BEFORE any claim with terminal
//     DataPathUnverifiable listing the attachments that CAN be verified.
package srv6service

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/compat"
	"github.com/mairp/agentic-netops/pkg/reasons"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Capability record keys (contracts/capability-record.md, data-model.md §5).
const (
	// KeySAISRV6 is the SRv6 SAI capability assertion ("true" or "false").
	KeySAISRV6 = "cap-sai-srv6"
	// KeySRv6Supported lists the proven variants, comma-separated.
	KeySRv6Supported = "srv6-supported"
	// KeyProbeAttachments lists the registered probe hosts, comma-separated,
	// each as "node/logical-port" — the same key the Check.ProbeFrom key
	// names resolve against.
	KeyProbeAttachments = "srv6-probe-attachments"
)

// Capability is the decision-relevant view of the capability record.
type Capability struct {
	// SAISRV6 is true only when the record says exactly "true".
	SAISRV6 bool
	// Supported holds the proven variants (srv6-supported).
	Supported []string
	// ProbeAttachments holds the registered probe hosts ("node/port").
	ProbeAttachments []string
	// Found reports whether the record itself was readable.
	Found bool
	// Provenance names where the view came from, for the refusal message.
	Provenance string
}

// readCapability fetches the record through r (an uncached reader — the
// reconciler passes manager.GetAPIReader(); see compat.PinReader).
func readCapability(ctx context.Context, r compat.PinReader) (*Capability, *Refusal) {
	var cm corev1.ConfigMap
	if err := r.Get(ctx, client.ObjectKey{
		Name: compat.PinsConfigMapName, Namespace: compat.PinsConfigMapNamespace,
	}, &cm); err != nil {
		return nil, &Refusal{
			Reason: reasons.ReasonCapabilityMissing,
			Message: fmt.Sprintf("capability record %s/%s is unreadable: %v",
				compat.PinsConfigMapNamespace, compat.PinsConfigMapName, err),
			Kind: refusalCap,
		}
	}
	cap := &Capability{
		Found:      true,
		Provenance: fmt.Sprintf("configmap %s/%s", compat.PinsConfigMapNamespace, compat.PinsConfigMapName),
	}
	if v := strings.TrimSpace(cm.Data[KeySAISRV6]); v == "true" {
		cap.SAISRV6 = true
	}
	cap.Supported = splitCSV(cm.Data[KeySRv6Supported])
	cap.ProbeAttachments = splitCSV(cm.Data[KeyProbeAttachments])
	return cap, nil
}

// checkCapability enforces C5 then C8, in that order, and never claims.
func checkCapability(svc *v1alpha1.SRv6Service, cap *Capability) *Refusal {
	// C5: the capability assertion must be true.
	if cap == nil || !cap.SAISRV6 {
		provenance := "record absent"
		if cap != nil {
			provenance = fmt.Sprintf("key %s is not \"true\"", KeySAISRV6)
		}
		return &Refusal{
			Reason:  reasons.ReasonCapabilityMissing,
			Message: fmt.Sprintf("SRv6 is not proven on this site (%s; %s)", provenance, capProvenance(cap)),
			Kind:    refusalCap,
		}
	}
	// C8: every attachment needs a registered probe host, decided BEFORE any
	// claim. The refusal lists the attachments that CAN be verified.
	var missing, verifiable []string
	for _, att := range svc.Spec.Attachments {
		key := att.Node + "/" + att.Port
		if contains(cap.ProbeAttachments, key) {
			verifiable = append(verifiable, key)
		} else {
			missing = append(missing, key)
		}
	}
	if len(missing) > 0 {
		return &Refusal{
			Reason: reasons.ReasonDataPathUnverifiable,
			Message: fmt.Sprintf("no probe host registered for %s (verifiable attachments: %s)",
				joinNames(missing), joinNames(verifiable)),
			Kind: refusalCap,
		}
	}
	return nil
}

func capProvenance(cap *Capability) string {
	if cap == nil {
		return "no record"
	}
	return cap.Provenance
}

func contains(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}

// splitCSV splits a comma-separated record value, trimming whitespace and
// dropping empties, in a stable (sorted) order for message determinism.
func splitCSV(v string) []string {
	var out []string
	for _, part := range strings.Split(v, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	sort.Strings(out)
	return out
}
