// SPDX-License-Identifier: Apache-2.0
//
// Drift disclosure (quickstart Q6, T407): a per-node check that fails on an
// unchanged plan is OBSERVED — Ready=False naming the node and the check —
// before the controller repairs the drift by re-applying the idempotent ops.
// The repair itself must still need no operator action.

package srv6service

import (
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/reasons"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestSetDriftObservedNamesNodeAndCheck(t *testing.T) {
	st := &v1alpha1.SRv6ServiceStatus{
		Conditions: []metav1.Condition{
			{Type: ConditionReady, Status: metav1.ConditionTrue, Reason: reasons.ReasonVerified},
		},
	}
	setDriftObserved(st, 4, &Refusal{
		Kind: refusalCheck,
		Reason: reasons.ReasonCheckFailed,
		// the verify.go shape: "check <name> failed on node <node>: <detail>"
		Message: "check steering-route failed on node leaf01: no encap route",
	})

	var ready, degraded *metav1.Condition
	for i := range st.Conditions {
		switch st.Conditions[i].Type {
		case ConditionReady:
			ready = &st.Conditions[i]
		case ConditionDegraded:
			degraded = &st.Conditions[i]
		}
	}
	if ready == nil || ready.Status != metav1.ConditionFalse {
		t.Fatalf("Ready = %+v, want False during drift", ready)
	}
	if ready != nil && ready.ObservedGeneration != 4 {
		t.Errorf("observedGeneration = %d, want 4", ready.ObservedGeneration)
	}
	for _, c := range []*metav1.Condition{ready, degraded} {
		if c == nil {
			continue
		}
		if c.Reason != reasons.ReasonCheckFailed {
			t.Errorf("%s reason = %q, want %q", c.Type, c.Reason, reasons.ReasonCheckFailed)
		}
		if !strings.Contains(c.Message, "leaf01") || !strings.Contains(c.Message, "steering-route") {
			t.Errorf("%s message %q must name the node and the check", c.Type, c.Message)
		}
	}
	if degraded == nil || degraded.Status != metav1.ConditionTrue {
		t.Errorf("Degraded = %+v, want True during drift", degraded)
	}
}
