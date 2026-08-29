package unit

import (
	"testing"

	"github.com/mairp/ainetops/pkg/model"
	"github.com/mairp/ainetops/pkg/render"
)

func TestRenderBGP_EVPNNeighbors(t *testing.T) {
	g := model.BGPGlobal{ASN: 65000, RouterID: "1.1.1.1"}
	neis := []model.BGPNeighbor{{NeighborAddress: "10.0.0.2", PeerASN: 65001, EVPN: true}}
	res := render.RenderBGP(g, neis)
	if _, ok := res["/network-instances/network-instance"]; !ok {
		t.Fatalf("expected global bgp path")
	}
	if _, ok := res["/network-instances/network-instance/protocols/bgp/neighbors"]; !ok {
		t.Fatalf("expected neighbors path")
	}
}
