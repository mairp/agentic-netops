package unit

import (
	"os"
	"path/filepath"
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
	reg, err := os.ReadFile(filepath.Join("..", "..", "pkg", "register", "oc_vs_sonic.yaml"))
	if err != nil {
		t.Fatalf("read register: %v", err)
	}
	if err := sdc.ValidateSpecAgainstRegister(m, reg); err != nil {
		t.Fatalf("register validation failed: %v", err)
	}
}
