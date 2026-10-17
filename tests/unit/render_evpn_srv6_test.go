// SPDX-License-Identifier: Apache-2.0
package unit

import (
	"os"
	"path/filepath"
	"sort"
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

// TestEVPN_SRv6_RenderersAndRegister exercises the schema-backed SRv6
// renderers (SRV6_MY_LOCATORS, SRV6_MY_SIDS — the only SRv6 tables in the
// pinned image's YANG) and asserts the register covers every rendered path.
func TestEVPN_SRv6_RenderersAndRegister(t *testing.T) {
	vrf := model.NetworkInstance{Name: "tenant-a", Type: "L3VRF", RD: "65000:100", ImportRT: []string{"65000:100"}, ExportRT: []string{"65000:100"}}
	m := map[string]any{}
	merge(m,
		render.RenderNetworkInstances([]model.NetworkInstance{vrf}),
		render.RenderL3VNI(vrf, 10100),
		render.RenderEVPNType5(vrf),
		render.RenderIRB(vrf, 10, model.IRB{GatewayIPv4: "10.0.10.1/24", GatewayIPv6: "2001:db8:10::1/64"}),
	)
	// Locators are bootstrap-owned (FR-006); the decap SID row is rendered
	// for schema coverage only — it does not program the dataplane
	// (spike-sid-write), so the as-built plan uses kernel routes.
	merge(m,
		render.RenderSRv6MyLocators([]model.SRv6MyLocator{
			{Node: "leaf02", Prefix: "fcbb:bbbb:2::/48"},
			{Node: "leaf01", Prefix: "fcbb:bbbb:1::/48"},
		}),
		render.RenderSRv6MySids([]model.SRv6MySid{
			{Node: "leaf01", Prefix: "fcbb:bbbb:1:11::/64", Action: "uDT46", DecapVRF: vrf.Name},
			{Node: "leaf02", Prefix: "fcbb:bbbb:2:11::/64", Action: "uDT46", DecapVRF: vrf.Name},
		}),
	)

	srv6, ok := m["/sonic-srv6:sonic-srv6/SRV6_MY_LOCATORS"].([]map[string]any)
	if !ok || len(srv6) != 2 {
		t.Fatalf("expected 2 SRV6_MY_LOCATORS rows, got %#v", m["/sonic-srv6:sonic-srv6/SRV6_MY_LOCATORS"])
	}
	// Rows are emitted in sorted node order for determinism.
	if srv6[0]["locator"] != "loc-leaf01" || srv6[1]["locator"] != "loc-leaf02" {
		t.Fatalf("unexpected locator rows: %#v", srv6)
	}
	if srv6[0]["prefix"] != "fcbb:bbbb:1::/48" {
		t.Fatalf("unexpected locator prefix: %#v", srv6[0])
	}
	sids, ok := m["/sonic-srv6:sonic-srv6/SRV6_MY_SIDS"].([]map[string]any)
	if !ok || len(sids) != 2 {
		t.Fatalf("expected 2 SRV6_MY_SIDS rows, got %#v", m["/sonic-srv6:sonic-srv6/SRV6_MY_SIDS"])
	}
	if sids[0]["locator"] != "loc-leaf01" || sids[0]["sid"] != "fcbb:bbbb:1:11::/64" || sids[0]["action"] != "uDT46" || sids[0]["decap_vrf"] != "tenant-a" {
		t.Fatalf("unexpected SID row: %#v", sids[0])
	}

	// Only the two schema-backed SRv6 paths may be present.
	srv6Paths := []string{}
	for p := range m {
		if len(p) > 15 && p[:15] == "/sonic-srv6:son" {
			srv6Paths = append(srv6Paths, p)
		}
	}
	sort.Strings(srv6Paths)
	if len(srv6Paths) != 2 || srv6Paths[0] != "/sonic-srv6:sonic-srv6/SRV6_MY_LOCATORS" || srv6Paths[1] != "/sonic-srv6:sonic-srv6/SRV6_MY_SIDS" {
		t.Fatalf("unexpected SRv6 paths in spec: %v", srv6Paths)
	}

	reg, err := os.ReadFile(filepath.Join("..", "..", "pkg", "register", "oc_vs_sonic.yaml"))
	if err != nil {
		t.Fatalf("read register: %v", err)
	}
	if err := sdc.ValidateSpecAgainstRegister(m, reg); err != nil {
		t.Fatalf("register validation failed: %v", err)
	}
}
