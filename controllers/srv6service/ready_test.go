// SPDX-License-Identifier: Apache-2.0
//
// Ready-outcome persistence (contracts/srv6service-crd.md §4, quickstart Q5):
// the Verified write records not only the conditions and the plan hashes but
// ALSO status.allocations — every identifier the controller claimed, each
// traceable to a claim carrying the correlation id. Until it is persisted the
// readers (srv6_service.sh --readback, the tier, the operator) cannot see what
// was claimed, and reuseAllocation cannot short-circuit.

package srv6service

import (
	"testing"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/reasons"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestSetReadyOutcomePersistsAllocations(t *testing.T) {
	st := &v1alpha1.SRv6ServiceStatus{}
	alloc := &v1alpha1.Allocations{
		ServiceID: 7,
		VRF:       "Vrf7",
		ClientPrefixes: map[string]string{
			"leaf01": "192.168.35.0/24",
			"leaf02": "192.168.36.0/24",
		},
	}
	hashes := map[string]string{"leaf01": "aa", "leaf02": "bb"}
	spec := &v1alpha1.SRv6ServiceSpec{Tenant: "acme"}

	setReadyOutcome(st, 3, hashes, spec, "srv6-ip-vrf-vpn", "spine01", alloc)

	if st.Allocations == nil {
		t.Fatal("status.allocations not persisted at Ready")
	}
	if st.Allocations.VRF != "Vrf7" || st.Allocations.ServiceID != 7 {
		t.Errorf("allocations vrf/serviceId = %q/%d, want Vrf7/7", st.Allocations.VRF, st.Allocations.ServiceID)
	}
	if st.Allocations.ClientPrefixes["leaf01"] != "192.168.35.0/24" ||
		st.Allocations.ClientPrefixes["leaf02"] != "192.168.36.0/24" {
		t.Errorf("clientPrefixes = %v, want leaf01 192.168.35.0/24 + leaf02 192.168.36.0/24",
			st.Allocations.ClientPrefixes)
	}
	if st.ConfigHashes["leaf01"] != "aa" || st.ConfigHashes["leaf02"] != "bb" {
		t.Errorf("configHashes = %v, want leaf01 aa + leaf02 bb", st.ConfigHashes)
	}
	if st.AppliedSpec == nil || st.AppliedSpec.Tenant != "acme" {
		t.Error("appliedSpec not persisted")
	}
	if st.CorrelationID != "srv6-ip-vrf-vpn" || st.ActivePath != "spine01" {
		t.Errorf("correlationId/activePath = %q/%q, want srv6-ip-vrf-vpn/spine01",
			st.CorrelationID, st.ActivePath)
	}
	var ready *metav1.Condition
	for i := range st.Conditions {
		if st.Conditions[i].Type == ConditionReady {
			ready = &st.Conditions[i]
		}
	}
	if ready == nil || ready.Status != metav1.ConditionTrue || ready.Reason != reasons.ReasonVerified {
		t.Errorf("Ready condition = %+v, want True/Verified", ready)
	}
	if ready != nil && ready.ObservedGeneration != 3 {
		t.Errorf("observedGeneration = %d, want 3", ready.ObservedGeneration)
	}
}
