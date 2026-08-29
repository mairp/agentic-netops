package unit

import (
	"testing"

	"github.com/mairp/ainetops/pkg/model"
	"github.com/mairp/ainetops/pkg/render"
	"github.com/mairp/ainetops/pkg/sdc"
)

func TestRegisterGuard_CatchesMissingPath(t *testing.T) {
	spec := map[string]any{
		"/interfaces/interface": map[string]any{"ok": true},
		"/unknown/path":        map[string]any{"bad": true},
	}
	if err := sdc.ValidateSpecAgainstRegister(spec, nil); err == nil {
		t.Fatalf("expected error for unregistered path")
	}
}

func TestRegisterGuard_PassesForRenderedPaths(t *testing.T) {
	// Build a representative spec using current renderers
	m := map[string]any{}
	for k, v := range render.RenderInterfaces([]model.Interface{{Name: "Ethernet1"}}, []model.Loopback{{Name: "Loopback0"}}) { m[k] = v }
	for k, v := range render.RenderBGP(model.BGPGlobal{ASN: 65000, RouterID: "1.1.1.1"}, []model.BGPNeighbor{{NeighborAddress: "10.0.0.2", PeerASN: 65001, EVPN: true}}) { m[k] = v }
	for k, v := range render.RenderVXLAN(model.VXLAN{SourceInterface: "Loopback0", UDPPort: 4789}, []model.VLAN{{ID: 10, Name: "blue", L2VNI: 10010}}) { m[k] = v }
	for k, v := range render.RenderSRv6(model.SRv6Locator{Name: "default", Prefix: "2001:db8:1::/48"}, []model.MySID{{SID: "2001:db8:1::1", Behavior: "End"}}) { m[k] = v }
	if err := sdc.ValidateSpecAgainstRegister(m, nil); err != nil {
		if !sdc.IsRegisterError(err) {
			t.Fatalf("unexpected error type: %v", err)
		}
		t.Fatalf("expected register to cover current rendered paths, got: %v", err)
	}
}
