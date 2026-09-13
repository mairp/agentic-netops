package unit

import (
	"testing"

	"github.com/mairp/agentic-netops/pkg/model"
	"github.com/mairp/agentic-netops/pkg/render"
	"github.com/mairp/agentic-netops/pkg/sdc"
)

func merge(m map[string]any, more ...map[string]any) map[string]any {
	for _, mm := range more {
		for k, v := range mm {
			m[k] = v
		}
	}
	return m
}

func TestEVPN_SRv6_RenderersAndRegister(t *testing.T) {
	vrf := model.NetworkInstance{Name: "tenant-a", Type: "L3VRF", RD: "65000:100", ImportRT: []string{"65000:100"}, ExportRT: []string{"65000:100"}}
	m := map[string]any{}
	merge(m,
		render.RenderNetworkInstances([]model.NetworkInstance{vrf}),
		render.RenderL3VNI(vrf, 10100),
		render.RenderEVPNType5(vrf),
		render.RenderIRB(vrf, 10, model.IRB{GatewayIPv4: "10.0.10.1/24", GatewayIPv6: "2001:db8:10::1/64"}),
	)
	loc := model.SRv6Locator{Name: "default", Prefix: "2001:db8:1::/48"}
	merge(m,
		render.RenderSRv6(loc, []model.MySID{{SID: "2001:db8:1::1", Behavior: "End"}}),
		render.RenderSRv6Behaviors([]string{"H.Encaps.Red", "End", "End.DT46"}),
		render.RenderSIDList("spine-path", []string{"2001:db8:1::a", "2001:db8:1::b"}),
		render.RenderSRPolicy(model.SRPolicy{Name: "policy1", Selector: "if:Ethernet1", SIDListRef: "spine-path"}),
	)
	// These renderers are the OpenConfig scaffolds, NOT the southbound this
	// fabric writes with: the write path is pkg/fabricplan, and its register is
	// pkg/register/oc_vs_srlinux.yaml (guarded by
	// TestRendererPathsCoveredByRegister). oc_vs_srlinux.yaml declares only the
	// SR Linux surfaces the executor actually touches, and SRv6 is not among
	// them — this site has no SRv6 data plane and says so rather than
	// pretending (FR-009). So the scaffolds are pinned against their own
	// declaration here: the test fails the moment one of them starts emitting a
	// path this list does not name.
	if err := sdc.ValidateSpecAgainstRegister(m, []byte(scaffoldRegister)); err != nil {
		t.Fatalf("register validation failed: %v", err)
	}
}

// scaffoldRegister is the declared path set of the pkg/render OpenConfig
// scaffolds. It is deliberately separate from pkg/register/oc_vs_srlinux.yaml:
// nothing here is written to the SR Linux fabric.
const scaffoldRegister = `entries:
  - path: /network-instances/network-instance
    prefer: openconfig
  - path: /network-instances/network-instance/l3vni
    prefer: openconfig
  - path: /network-instances/network-instance/evpn/type5
    prefer: openconfig
  - path: /network-instances/network-instance/bridges/irb
    prefer: openconfig
  - path: /sonic-srv6:sonic-srv6/SRV6_GLOBAL
    prefer: native
  - path: /sonic-srv6:sonic-srv6/MYSID
    prefer: native
  - path: /sonic-srv6:sonic-srv6/BEHAVIORS
    prefer: native
  - path: /sonic-srv6:sonic-srv6/SID_LIST
    prefer: native
  - path: /sonic-srv6:sonic-srv6/POLICY
    prefer: native
`
