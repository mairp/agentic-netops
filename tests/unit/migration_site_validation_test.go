// SPDX-License-Identifier: Apache-2.0
package unit

import (
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/pkg/migration"
)

func l2Input(t migration.ServiceType, vlans ...int) *migration.ServiceInput {
	eps := make([]migration.Endpoint, 0, len(vlans))
	nodes := []string{"leaf01", "leaf02"}
	for i, v := range vlans {
		eps = append(eps, migration.Endpoint{Node: nodes[i%len(nodes)], Attachment: "ethernet1", VLAN: v})
	}
	return &migration.ServiceInput{
		ServiceID: "svc1",
		Type:      t,
		Tenant:    "acme",
		RDRT:      &migration.RdRt{RD: "65000:5", ImportRT: []string{"65000:5"}, ExportRT: []string{"65000:5"}},
		L2VNI:     10004,
		Endpoints: eps,
		Policies:  migration.Policies{VPWSLimitedEquivalence: true},
	}
}

func causesOf(t *testing.T, err error) []string {
	t.Helper()
	if err == nil {
		return nil
	}
	ve, ok := err.(*migration.ValidationError)
	if !ok {
		t.Fatalf("expected *migration.ValidationError, got %T: %v", err, err)
	}
	return ve.Causes
}

func hasCause(causes []string, substr string) bool {
	for _, c := range causes {
		if strings.Contains(c, substr) {
			return true
		}
	}
	return false
}

// A bridge domain is one broadcast domain. VPLS enforced that from the start;
// VPWS and IRB did not, so the allocator's per-endpoint VLANs sailed through
// validation and every one of those services failed at the fabric with
// "references vlan N with no bridgeDomain" — after submission.
func TestEveryL2ServiceRequiresOneSharedVLAN(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   *migration.ServiceInput
	}{
		{"VPLS", l2Input(migration.ServiceVPLS, 108, 109)},
		{"VPWS", l2Input(migration.ServiceVPWS, 108, 109)},
	} {
		causes := causesOf(t, tc.in.ValidateAllOrNothing(0, false))
		if !hasCause(causes, "every endpoint must share one vlan") {
			t.Errorf("%s accepted two different endpoint vlans: %v", tc.name, causes)
		}
	}

	irb := l2Input(migration.ServiceIRB, 200, 201)
	irb.L3VNI = 10006
	irb.IRBGateway = &migration.IRBGateway{VRF: "vrf-acme", GatewayV4: "10.0.0.1/24", GatewayV6: "fd00::1/64"}
	if causes := causesOf(t, irb.ValidateAllOrNothing(0, false)); !hasCause(causes, "every endpoint must share one vlan") {
		t.Errorf("IRB accepted two different endpoint vlans: %v", causes)
	}

	// The shared-vlan shape still validates.
	if err := l2Input(migration.ServiceVPWS, 108, 108).ValidateAllOrNothing(0, false); err != nil {
		t.Errorf("a VPWS on one shared vlan was rejected: %v", err)
	}
}

// An L3VNI the renderer cannot derive a VLAN for is rejected before anything
// is submitted, not after the controller fails to render the object.
func TestUnrenderableL3VNIIsRejected(t *testing.T) {
	in := &migration.ServiceInput{
		ServiceID: "svc1", Type: migration.ServiceL3VPN, Tenant: "acme",
		RDRT:      &migration.RdRt{RD: "65000:5", ImportRT: []string{"65000:5"}, ExportRT: []string{"65000:5"}},
		L3VNI:     20401,
		AF:        &migration.AddressFamilies{IPv4Prefixes: []string{"10.0.0.0/24"}},
		Endpoints: []migration.Endpoint{{Node: "leaf01", Attachment: "wan1", VRF: "vrf-acme"}},
	}
	if causes := causesOf(t, in.ValidateAllOrNothing(0, false)); !hasCause(causes, "10000-14094") {
		t.Errorf("an L3VNI with no derivable VLAN was accepted: %v", causes)
	}
	in.L3VNI = 10020
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Errorf("a renderable L3VNI was rejected: %v", err)
	}
}

// The site's own inventory is the last gate before objects exist on the
// cluster: an endpoint naming a node or port this fabric does not have is
// refused here, with the real choices named, instead of being submitted and
// failing at render time with nothing rolled back.
func TestSiteInventoryRefusesEndpointsTheFabricCannotHonour(t *testing.T) {
	t.Setenv("FABRIC_NODE_MAP", `{"leaf01":"clab-leaf01","leaf02":"clab-leaf02"}`)
	t.Setenv("FABRIC_PORT_MAP", `{"wan1":"eth4","ethernet1":"eth3"}`)

	in := l2Input(migration.ServiceVPLS, 108, 108)
	in.Endpoints[1].Node = "leaf1"
	in.Endpoints[1].Attachment = "ethernet5"
	causes := causesOf(t, in.ValidateAllOrNothing(0, false))
	if !hasCause(causes, `"leaf1" is not a node at this site`) {
		t.Errorf("unknown node accepted: %v", causes)
	}
	if !hasCause(causes, `"ethernet5" is not an attachment point at this site`) {
		t.Errorf("unknown attachment accepted: %v", causes)
	}
	if !hasCause(causes, "wan1") {
		t.Errorf("rejection does not name the site's real attachment points: %v", causes)
	}

	// Spelling is not intent: a known name in another case still resolves.
	ok := l2Input(migration.ServiceVPLS, 108, 108)
	ok.Endpoints[0].Node = "Leaf01"
	ok.Endpoints[0].Attachment = "Ethernet1"
	if err := ok.ValidateAllOrNothing(0, false); err != nil {
		t.Errorf("a differently spelled but known endpoint was rejected: %v", err)
	}
}

// Without a configured site (the CLI, the unit suite) nothing is invented.
func TestNoSiteInventoryValidatesNothing(t *testing.T) {
	t.Setenv("FABRIC_NODE_MAP", "")
	t.Setenv("FABRIC_PORT_MAP", "")
	in := l2Input(migration.ServiceVPLS, 108, 108)
	in.Endpoints[1].Node = "some-node-elsewhere"
	if err := in.ValidateAllOrNothing(0, false); err != nil {
		t.Errorf("validation invented a site inventory: %v", err)
	}
}

// An IRB carries the address families the operator asked for. Requiring both
// gateways forced every IRB to carry IPv6 whether or not it was requested.
func TestIRBNeedsAtLeastOneGatewayNotBoth(t *testing.T) {
	base := func() *migration.ServiceInput {
		in := l2Input(migration.ServiceIRB, 200, 200)
		in.L3VNI = 10006
		return in
	}
	v4only := base()
	v4only.IRBGateway = &migration.IRBGateway{VRF: "vrf-acme", GatewayV4: "10.30.0.1/24"}
	if err := v4only.ValidateAllOrNothing(0, false); err != nil {
		t.Errorf("an IPv4-only IRB was rejected: %v", err)
	}
	v6only := base()
	v6only.IRBGateway = &migration.IRBGateway{VRF: "vrf-acme", GatewayV6: "fd00:30::1/64"}
	if err := v6only.ValidateAllOrNothing(0, false); err != nil {
		t.Errorf("an IPv6-only IRB was rejected: %v", err)
	}
	neither := base()
	neither.IRBGateway = &migration.IRBGateway{VRF: "vrf-acme"}
	if causes := causesOf(t, neither.ValidateAllOrNothing(0, false)); !hasCause(causes, "at least one of gatewayIPv4/gatewayIPv6") {
		t.Errorf("an IRB with no gateway at all was accepted: %v", causes)
	}
}
