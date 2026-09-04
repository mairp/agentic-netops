// SPDX-License-Identifier: Apache-2.0
package fabricplan

import (
	"slices"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/pkg/kubenet"
)

func TestL3PlanOriginatesAndVerifiesType5(t *testing.T) {
	net := &kubenet.Network{Spec: map[string]any{
		"routers": []any{map[string]any{
			"name": "vrf-6cf2d23d9991475", "l3vni": float64(10018),
			"rd": "65000:18", "routeTargets": map[string]any{
				"import": []any{"65000:18"}, "export": []any{"65000:18"},
			},
			"prefixes": []any{"10.0.0.7/24"},
		}},
		"attachments": []any{map[string]any{
			"node": "leaf01", "attachment": "wan1", "vrf": "vrf-6cf2d23d9991475",
		}},
	}}

	plan, err := ForNetwork(net, Options{Ports: PortMapper{"wan1": "eth4"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf01"]
	if np == nil {
		t.Fatal("leaf01 plan missing")
	}

	var vty, frr []string
	for _, op := range np.Ops {
		if len(op.VTYSh) > 0 {
			vty = op.VTYSh
		}
		if len(op.FRRConf) > 0 {
			frr = op.FRRConf
		}
	}
	for _, want := range []string{
		"redistribute connected",
		"address-family l2vpn evpn",
		"advertise ipv4 unicast",
		"rd 65000:18",
		"route-target both 65000:18",
	} {
		if !slices.Contains(vty, want) {
			t.Errorf("vtysh operation missing %q: %#v", want, vty)
		}
		if !slices.Contains(frr, "  "+want) && !slices.Contains(frr, " "+want) {
			t.Errorf("durable FRR block missing %q: %#v", want, frr)
		}
	}

	wantChecks := map[string]bool{
		"Tenant VRF: Vrf-6cf2d23d99": false,
		"[5]:[0]:[24]:[10.0.0.0]":    false,
	}
	for _, check := range np.Checks {
		if check.Type == "vtysh-contains" {
			if check.Expect == "[5]:[0]:[24]:[10.0.0.0]" && check.Command != "show bgp l2vpn evpn route rd 65000:18" {
				t.Errorf("Type-5 check is not scoped to the service RD: %#v", check)
			}
			if _, ok := wantChecks[check.Expect]; ok {
				wantChecks[check.Expect] = true
			}
		}
	}
	for want, found := range wantChecks {
		if !found {
			t.Errorf("control-plane check for %q missing: %#v", want, np.Checks)
		}
	}
}

func TestL3PlanRejectsInvalidPrefix(t *testing.T) {
	net := &kubenet.Network{Spec: map[string]any{
		"routers": []any{map[string]any{
			"name": "vrf-red", "l3vni": float64(10018), "prefixes": []any{"not-a-prefix"},
		}},
		"attachments": []any{map[string]any{
			"node": "leaf01", "attachment": "wan1", "vrf": "vrf-red",
		}},
	}}

	if _, err := ForNetwork(net, Options{Ports: PortMapper{"wan1": "eth4"}}); err == nil {
		t.Fatal("ForNetwork accepted an invalid service prefix")
	}
}

func TestType5RouteNeedleMasksHostBits(t *testing.T) {
	got, err := type5RouteNeedle("10.0.0.7/24")
	if err != nil {
		t.Fatal(err)
	}
	if want := "[5]:[0]:[24]:[10.0.0.0]"; got != want {
		t.Fatalf("type5RouteNeedle = %q, want %q", got, want)
	}
}

// --- L2 ----------------------------------------------------------------------

func l2Network(vlan int64, l2vni int64) *kubenet.Network {
	return &kubenet.Network{Spec: map[string]any{
		"bridgeDomains": []any{map[string]any{
			"name": "bd-vpls1", "vlan": float64(vlan), "l2vni": float64(l2vni),
			"evpn": map[string]any{"routeTargets": map[string]any{"export": []any{"65000:5"}}},
		}},
		"attachments": []any{
			map[string]any{"node": "leaf01", "attachment": "ethernet1", "vlan": float64(vlan)},
			map[string]any{"node": "leaf02", "attachment": "ethernet1", "vlan": float64(vlan)},
		},
	}}
}

func allShell(np *NodePlan) string {
	var b strings.Builder
	for _, op := range np.Ops {
		for _, s := range op.Shell {
			b.WriteString(s)
			b.WriteString("\n")
		}
	}
	return b.String()
}

// The VXLAN device SONiC's vxlanmgrd creates is named after the VLAN, not the
// VNI. Naming it after the VNI made every vtep command a no-op against a
// device that does not exist, so the bridge domain stayed local-only while the
// plan reported success.
func TestL2PlanAddressesTheVTEPByVLANNotVNI(t *testing.T) {
	plan, err := ForNetwork(l2Network(108, 10004), Options{Ports: PortMapper{"ethernet1": "eth3"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf01"]
	if np == nil {
		t.Fatal("leaf01 plan missing")
	}
	shell := allShell(np)
	if !strings.Contains(shell, "vtep1-108") {
		t.Errorf("L2 plan never touches vtep1-108:\n%s", shell)
	}
	if strings.Contains(shell, "vtep1-10004") {
		t.Errorf("L2 plan addresses the vtep by VNI (vtep1-10004), which is not a device:\n%s", shell)
	}
	var vtepChecked bool
	for _, ck := range np.Checks {
		if ck.Type == "ip-master" && ck.Iface == "vtep1-108" && ck.Master == "Bridge" {
			vtepChecked = true
		}
	}
	if !vtepChecked {
		t.Errorf("no check proves the L2VNI's vtep is bridged: %#v", np.Checks)
	}
}

// A port already carrying an untagged service keeps it: the new service lands
// tagged rather than stealing the untagged role from the service that has it.
func TestAccessPortClaimsUntaggedOnlyWhenFree(t *testing.T) {
	plan, err := ForNetwork(l2Network(108, 10004), Options{Ports: PortMapper{"ethernet1": "eth3"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	shell := allShell(plan.Nodes["leaf01"])
	if !strings.Contains(shell, "grep -qw PVID") {
		t.Errorf("access port does not test for an existing PVID before claiming it:\n%s", shell)
	}
	if strings.Contains(shell, "python3") {
		t.Errorf("access port still probes PVID through the JSON shape iproute2 does not emit:\n%s", shell)
	}
}

// --- IRB ---------------------------------------------------------------------

func irbNetwork() *kubenet.Network {
	return &kubenet.Network{Spec: map[string]any{
		"bridgeDomains": []any{map[string]any{
			"name": "bd-irb1", "vlan": float64(200), "l2vni": float64(10005),
			"irb": map[string]any{
				"vrf": "vrf-irb1", "gatewayIPv4": "10.30.0.1/24", "gatewayIPv6": "fd00:30::1/64",
			},
		}},
		"routers": []any{map[string]any{
			"name": "vrf-irb1", "l3vni": float64(10006), "rd": "65000:6",
			"routeTargets": map[string]any{"import": []any{"65000:6"}, "export": []any{"65000:6"}},
		}},
		"attachments": []any{
			map[string]any{"node": "leaf01", "attachment": "ethernet1", "vlan": float64(200)},
		},
	}}
}

// An IRB is L2 AND L3. While kubenet.BridgeDomain had no irb field the routed
// half was dropped on the floor and the operator silently got a VPLS.
func TestIRBPlanRendersBothHalves(t *testing.T) {
	plan, err := ForNetwork(irbNetwork(), Options{Ports: PortMapper{"ethernet1": "eth3"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf01"]
	if np == nil {
		t.Fatal("leaf01 plan missing")
	}

	var redis, vty []string
	var gcu []map[string]any
	for _, op := range np.Ops {
		redis = append(redis, op.Redis...)
		vty = append(vty, op.VTYSh...)
		gcu = append(gcu, op.GCU...)
	}
	joinedRedis := strings.Join(redis, "\n")
	// L2 half: the bridge domain's own VLAN row and L2VNI tunnel map.
	if !strings.Contains(joinedRedis, "map_10005_Vlan200") {
		t.Errorf("IRB plan is missing the L2VNI tunnel map:\n%s", joinedRedis)
	}
	// L3 half: the VRF row, the derived L3VLAN and the L3VNI tunnel map.
	if len(gcu) == 0 {
		t.Error("IRB plan never declares a VRF through the GCU")
	}
	if !strings.Contains(joinedRedis, "map_10006_Vlan4006") {
		t.Errorf("IRB plan is missing the L3VNI tunnel map:\n%s", joinedRedis)
	}
	if !slices.Contains(vty, "vni 10006") {
		t.Errorf("IRB plan never binds the L3VNI to the VRF in FRR: %#v", vty)
	}

	// The gateway SVI is the point of an IRB: it lives in the VRF and carries
	// both declared gateway addresses.
	want := map[string]bool{
		"ip-master:Vlan200=Vrf-irb1":    false,
		"ip-addr:Vlan200=10.30.0.1/24":  false,
		"ip-addr:Vlan200=fd00:30::1/64": false,
	}
	for _, ck := range np.Checks {
		switch ck.Type {
		case "ip-master":
			if ck.Iface == "Vlan200" && ck.Master == "Vrf-irb1" {
				want["ip-master:Vlan200=Vrf-irb1"] = true
			}
		case "ip-addr":
			if ck.Iface == "Vlan200" {
				want["ip-addr:Vlan200="+ck.Addr] = true
			}
		}
	}
	for k, found := range want {
		if !found {
			t.Errorf("IRB plan does not verify %s: %#v", k, np.Checks)
		}
	}
	// Both address families are advertised: an IRB with a v6 gateway that only
	// advertises v4 is half a service.
	for _, afi := range []string{"advertise ipv4 unicast", "advertise ipv6 unicast"} {
		if !slices.Contains(vty, afi) {
			t.Errorf("IRB plan does not %q: %#v", afi, vty)
		}
	}
}

func TestIRBWithoutItsRouterIsRejected(t *testing.T) {
	net := irbNetwork()
	delete(net.Spec, "routers")
	if _, err := ForNetwork(net, Options{Ports: PortMapper{"ethernet1": "eth3"}}); err == nil {
		t.Fatal("ForNetwork rendered an IRB whose irb.vrf names no router")
	}
}

// --- port map ----------------------------------------------------------------

func TestPortMapperFoldsSpelling(t *testing.T) {
	m := PortMapper{"ethernet1": "eth3", "wan1": "eth4"}
	for _, spelling := range []string{"ethernet1", "Ethernet1", "ETHERNET1", "ethernet-1", "Ethernet_1"} {
		got, err := m.Port(spelling)
		if err != nil {
			t.Errorf("Port(%q): %v", spelling, err)
			continue
		}
		if got != "eth3" {
			t.Errorf("Port(%q) = %q, want eth3", spelling, got)
		}
	}
	if _, err := m.Port("ethernet5"); err == nil {
		t.Fatal("Port accepted a port the site does not have")
	} else if !strings.Contains(err.Error(), "ethernet1, wan1") {
		t.Errorf("rejection does not name the site's ports: %v", err)
	}
}

func TestBridgeDomainInDerivedL3VLANBandIsRejected(t *testing.T) {
	if _, err := ForNetwork(l2Network(4007, 10004), Options{Ports: PortMapper{"ethernet1": "eth3"}}); err == nil {
		t.Fatal("ForNetwork accepted a service vlan inside the derived-L3VLAN band")
	}
}

func TestAttachmentVLANWithNoBridgeDomainNamesWhatExists(t *testing.T) {
	net := l2Network(108, 10004)
	atts := net.Spec["attachments"].([]any)
	atts[1].(map[string]any)["vlan"] = float64(109)
	_, err := ForNetwork(net, Options{Ports: PortMapper{"ethernet1": "eth3"}})
	if err == nil {
		t.Fatal("ForNetwork accepted an attachment on a vlan no bridgeDomain declares")
	}
	if !strings.Contains(err.Error(), "vlan 108") {
		t.Errorf("rejection does not name the vlan that does exist: %v", err)
	}
}

// Membership checks alone cannot tell a service's own VXLAN device from one it
// inherited: SONiC names the device after the VLAN, so a service reusing a
// VLAN another service holds passes every bridge check while the overlay
// carries the other VNI (seen live: leaf01 vtep1-300 on vni 10021 for a
// service allocated 10022).
func TestPlansVerifyTheVTEPCarriesTheirOwnVNI(t *testing.T) {
	l2, err := ForNetwork(l2Network(108, 10004), Options{Ports: PortMapper{"ethernet1": "eth3"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	assertVXLANIDCheck(t, l2.Nodes["leaf01"], "vtep1-108", "10004")

	l3 := &kubenet.Network{Spec: map[string]any{
		"routers": []any{map[string]any{"name": "vrf-a", "l3vni": float64(10018), "prefixes": []any{"10.0.0.0/24"}}},
		"attachments": []any{map[string]any{
			"node": "leaf01", "attachment": "wan1", "vrf": "vrf-a",
		}},
	}}
	plan, err := ForNetwork(l3, Options{Ports: PortMapper{"wan1": "eth4"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	assertVXLANIDCheck(t, plan.Nodes["leaf01"], "vtep1-4018", "10018")
}

func assertVXLANIDCheck(t *testing.T, np *NodePlan, iface, vni string) {
	t.Helper()
	for _, ck := range np.Checks {
		if ck.Type == "link-vxlan-id" && ck.Iface == iface && ck.Expect == vni {
			return
		}
	}
	t.Errorf("no check proves %s carries vni %s: %#v", iface, vni, np.Checks)
}

// zebra can know an L3VNI while bgpd does not: a service with a correct VRF
// row, SVI, bridged VXLAN device and `vrf X / vni N` in FRR still answered
// "VNI not found" to `show bgp l2vpn evpn vni N`, and reconciling forever
// could not heal it because every op was already a no-op.
func TestL3PlanReTriggersEVPNVNIAdoption(t *testing.T) {
	net := &kubenet.Network{Spec: map[string]any{
		"routers": []any{map[string]any{"name": "vrf-a", "l3vni": float64(10007), "prefixes": []any{"10.0.0.0/24"}}},
		"attachments": []any{map[string]any{
			"node": "leaf01", "attachment": "wan1", "vrf": "vrf-a",
		}},
	}}
	plan, err := ForNetwork(net, Options{Ports: PortMapper{"wan1": "eth4"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	shell := allShell(plan.Nodes["leaf01"])
	if !strings.Contains(shell, "no vni 10007") || !strings.Contains(shell, "show bgp l2vpn evpn vni 10007") {
		t.Errorf("no guarded re-binding of the L3VNI:\n%s", shell)
	}
	// Guarded: a healthy service must read state and write nothing.
	if !strings.Contains(shell, "grep -q 'Tenant VRF: Vrf-a' || {") {
		t.Errorf("the re-binding is not conditional on bgpd having missed the VNI:\n%s", shell)
	}
}

// vlanmgrd builds the Vlan device from the CONFIG_DB row and only then marks
// the vlan ready in STATE_DB — the signal vxlanmgrd waits on before building
// the VXLAN device. Creating the device first makes vlanmgrd's create fail,
// and it does not retry, so the service ends up with a Vlan device, no vtep,
// and no overlay at all.
func TestSVIWaitsForTheVLANManagerBeforeBuildingTheDevice(t *testing.T) {
	net := &kubenet.Network{Spec: map[string]any{
		"routers": []any{map[string]any{"name": "vrf-a", "l3vni": float64(10007), "prefixes": []any{"10.0.0.0/24"}}},
		"attachments": []any{map[string]any{
			"node": "leaf01", "attachment": "wan1", "vrf": "vrf-a",
		}},
	}}
	plan, err := ForNetwork(net, Options{Ports: PortMapper{"wan1": "eth4"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	shell := allShell(plan.Nodes["leaf01"])
	create := "ip link add Vlan4007 link Bridge type vlan id 4007"
	if !strings.Contains(shell, create) {
		t.Fatalf("the SVI is never created at all:\n%s", shell)
	}
	for _, line := range strings.Split(shell, "\n") {
		if strings.Contains(line, create) {
			if !strings.Contains(line, "seq 1 15") {
				t.Errorf("the SVI is created without waiting for vlanmgrd first: %q", line)
			}
			return
		}
	}
}

// A rollback must never delete a device a SONiC manager owns. vlanmgrd runs
// its own `ip link del Vlan<id>` when the CONFIG_DB row goes away, and when
// the device is already gone it treats that failure as fatal and EXITS —
// after which nothing on that node gets a VLAN again. One service's teardown
// broke every L2 service the fabric would have built afterwards.
func TestRollbackNeverDeletesAManagerOwnedDevice(t *testing.T) {
	for name, net := range map[string]*kubenet.Network{
		"L2":  l2Network(108, 10004),
		"IRB": irbNetwork(),
		"L3": {Spec: map[string]any{
			"routers": []any{map[string]any{"name": "vrf-a", "l3vni": float64(10007), "prefixes": []any{"10.0.0.0/24"}}},
			"attachments": []any{map[string]any{
				"node": "leaf01", "attachment": "wan1", "vrf": "vrf-a",
			}},
		}},
	} {
		ports := PortMapper{"ethernet1": "eth3", "wan1": "eth4"}
		plan, err := ForNetwork(net, Options{Ports: ports})
		if err != nil {
			t.Fatalf("%s: ForNetwork: %v", name, err)
		}
		for _, op := range plan.Nodes["leaf01"].Rollback {
			for _, cmd := range op.Shell {
				if strings.Contains(cmd, "ip link del Vlan") || strings.Contains(cmd, "ip link del vtep") {
					t.Errorf("%s rollback deletes a manager-owned device: %q", name, cmd)
				}
			}
		}
	}
}
