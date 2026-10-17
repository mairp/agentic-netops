// SPDX-License-Identifier: Apache-2.0
//
// Allocation reuse (allocate.go): once the status carries the claimed
// identifiers, steady-state reconciles must NOT round-trip the kuid
// authority again — the claims are deterministic per correlation id, so a
// re-claim can only add churn (measured: the authority's in-memory index
// wedges under repeated claim traffic, quickstart incident 20:49). The
// controller's Reconcile wires reuseAllocation in front of Allocate.

package srv6service

import (
	"testing"

	"github.com/mairp/agentic-netops/api/v1alpha1"
)

func readyStatusWithAlloc() *v1alpha1.SRv6Service {
	svc := &v1alpha1.SRv6Service{}
	vlan := int64(0)
	_ = vlan
	svc.Status.CorrelationID = "srv6-ip-vrf-vpn"
	svc.Status.Allocations = &v1alpha1.Allocations{
		ServiceID:      1,
		VRF:            "Vrf1",
		ClientPrefixes: map[string]string{"leaf01": "192.168.35.0/24", "leaf02": "192.168.36.0/24"},
	}
	return svc
}

func TestReuseAllocationShortCircuitsAuthority(t *testing.T) {
	svc := readyStatusWithAlloc()
	svc.Spec.Attachments = []v1alpha1.Attachment{
		{Node: "leaf01", Port: "Ethernet12"},
		{Node: "leaf02", Port: "Ethernet12"},
	}
	alloc := reuseAllocation(svc, "srv6-ip-vrf-vpn", map[string]string{
		"leaf01": "fcbb:bbbb:3::/48", "leaf02": "fcbb:bbbb:4::/48",
	})
	if alloc == nil {
		t.Fatal("reuseAllocation returned nil for a fully-populated status; the reconcile would re-claim")
	}
	if alloc.Allocations.VRF != "Vrf1" || alloc.Allocations.ServiceID != 1 {
		t.Errorf("reused alloc = %s/%d, want Vrf1/1", alloc.Allocations.VRF, alloc.Allocations.ServiceID)
	}
	if alloc.Allocations.ClientPrefixes["leaf02"] != "192.168.36.0/24" {
		t.Errorf("reused clientPrefixes[leaf02] = %q", alloc.Allocations.ClientPrefixes["leaf02"])
	}
	if len(alloc.ServiceSIDs) != 2 {
		t.Errorf("serviceSIDs = %v, want one per attachment", alloc.ServiceSIDs)
	}
}

func TestReuseAllocationNilWhenStatusIncomplete(t *testing.T) {
	cases := map[string]func(*v1alpha1.SRv6Service){
		"no allocations":    func(s *v1alpha1.SRv6Service) { s.Status.Allocations = nil },
		"wrong correlation": func(s *v1alpha1.SRv6Service) { s.Status.CorrelationID = "other" },
		"zero service id":   func(s *v1alpha1.SRv6Service) { s.Status.Allocations.ServiceID = 0 },
		"missing prefix":    func(s *v1alpha1.SRv6Service) { delete(s.Status.Allocations.ClientPrefixes, "leaf02") },
	}
	for name, breakIt := range cases {
		svc := readyStatusWithAlloc()
		svc.Spec.Attachments = []v1alpha1.Attachment{
			{Node: "leaf01", Port: "Ethernet12"},
			{Node: "leaf02", Port: "Ethernet12"},
		}
		breakIt(svc)
		if alloc := reuseAllocation(svc, "srv6-ip-vrf-vpn", nil); alloc != nil {
			t.Errorf("%s: reuseAllocation = %+v, want nil (fresh claim required)", name, alloc)
		}
	}
}
