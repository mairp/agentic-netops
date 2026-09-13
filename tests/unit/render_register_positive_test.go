// SPDX-License-Identifier: Apache-2.0
package unit

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/mairp/agentic-netops/pkg/sdc"
)

// TestRendererPathsCoveredByRegister is the register guard (make verify-register).
//
// It does not assert against a hand-written list of paths: it RENDERS all five
// constructs through pkg/fabricplan on the real site port map and derives the
// path family of every gNMI path the plans carry — apply updates, rollback
// deletes and verification reads. Every one of those families must appear in
// pkg/register/oc_vs_srlinux.yaml. A renderer that starts writing to a new part
// of the SR Linux model therefore fails here until that surface is declared,
// with its OpenConfig counterpart and the reason the native path is used.
func TestRendererPathsCoveredByRegister(t *testing.T) {
	families, err := renderedPathFamilies()
	if err != nil {
		t.Fatalf("render constructs: %v", err)
	}
	if len(families) == 0 {
		t.Fatal("the renderer emitted no paths at all; the guard would pass vacuously")
	}
	reg, err := os.ReadFile(filepath.Join("..", "..", "pkg", "register", "oc_vs_srlinux.yaml"))
	if err != nil {
		t.Fatalf("read register: %v", err)
	}
	if err := sdc.ValidateSpecAgainstRegister(families, reg); err != nil {
		t.Fatalf("register coverage failed for the SR Linux renderer: %v\nrendered families: %v",
			err, sortedKeys(families))
	}
}

// The families the guard checks have to be the real device surfaces, not
// whatever the renderer happens to spell today. These are the ones the contract
// (contracts/srlinux-render-contract.md) names, so a renderer that silently
// stopped emitting one would be caught here rather than on the fabric.
func TestRenderedFamiliesCoverEveryConstruct(t *testing.T) {
	families, err := renderedPathFamilies()
	if err != nil {
		t.Fatalf("render constructs: %v", err)
	}
	for _, want := range []string{
		"/interface",
		"/interface/subinterface",
		"/interface/subinterface/oper-state",
		"/interface/subinterface/acl/input",
		"/network-instance",
		"/network-instance/oper-state",
		"/network-instance/protocols/bgp-evpn/bgp-instance/oper-state",
		"/network-instance/bgp-rib/afi-safi/evpn/rib-in-out/rib-out-post/ip-prefix-routes",
		"/tunnel-interface/vxlan-interface",
		"/tunnel-interface/vxlan-interface/oper-state",
		"/tunnel-interface/vxlan-interface/bridge-table/multicast-destinations/destination",
		"/acl/acl-filter",
		"/acl/acl-filter/entry",
	} {
		if _, ok := families[want]; !ok {
			t.Errorf("the renderer no longer emits %s; rendered families: %v", want, sortedKeys(families))
		}
	}
}
