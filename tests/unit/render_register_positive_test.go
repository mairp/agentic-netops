package unit

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/mairp/agentic-netops/pkg/model"
	"github.com/mairp/agentic-netops/pkg/render"
	"github.com/mairp/agentic-netops/pkg/sdc"
)

// This test ensures the current renderer output is fully covered by the in-repo register
// and thus would pass ValidateSpecAgainstRegister.
func TestRendererPathsCoveredByRegister(t *testing.T) {
	m := map[string]any{}
	merge := func(mm map[string]any) {
		for k, v := range mm {
			m[k] = v
		}
	}
	merge(render.RenderInterfaces([]model.Interface{{Name: "Ethernet1"}}, []model.Loopback{{Name: "Loopback0"}}))
	merge(render.RenderBGP(model.BGPGlobal{ASN: 65000, RouterID: "1.1.1.1"}, []model.BGPNeighbor{{NeighborAddress: "10.0.0.2", PeerASN: 65001, EVPN: true}}))
	merge(render.RenderNetworkInstances([]model.NetworkInstance{{Name: "DEFAULT", Type: "DEFAULT"}}))
	merge(render.RenderVXLAN(model.VXLAN{SourceInterface: "Loopback0", UDPPort: 4789}, []model.VLAN{{ID: 10, Name: "blue", L2VNI: 10010}}))
	merge(render.RenderSRv6(model.SRv6Locator{Name: "default", Prefix: "2001:db8:1::/48"}, []model.MySID{{SID: "2001:db8:1::1", Behavior: "End"}}))
	// Add local VLANs to exercise SONiC-native VLAN register entries
	merge(render.RenderLocalVLANs([]model.VLAN{{ID: 120, Name: "vlan-local"}}, map[int][]string{120: {"Ethernet1"}}))
	reg, err := os.ReadFile(filepath.Join("..", "..", "pkg", "register", "oc_vs_sonic.yaml"))
	if err != nil {
		t.Fatalf("read register: %v", err)
	}
	if err := sdc.ValidateSpecAgainstRegister(m, reg); err != nil {
		t.Fatalf("register coverage failed: %v", err)
	}
}
