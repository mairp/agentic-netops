// SPDX-License-Identifier: Apache-2.0
package fabricplan

import (
	"encoding/json"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/mairp/agentic-netops/pkg/kubenet"
)

// srlPorts is the site port map the SR Linux lab publishes through
// FABRIC_PORT_MAP (deploy/agentic-netops/manifests/provider.yaml).
func srlPorts() PortMapper {
	return PortMapper{
		"wan1":      "ethernet-1/4",
		"ethernet1": "ethernet-1/3",
		"ethernet2": "ethernet-1/3",
		"ethernet3": "ethernet-1/3",
		"e1-1":      "ethernet-1/1",
		"e1-2":      "ethernet-1/2",
		"e1-3":      "ethernet-1/3",
		"e1-4":      "ethernet-1/4",
	}
}

// updatesAt returns every value this plan writes at path, decoded through JSON
// so a test asserts on what the executor will actually send.
func updatesAt(t *testing.T, np *NodePlan, path string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, op := range np.Ops {
		if op.GNMI == nil {
			continue
		}
		for _, u := range op.GNMI.Updates {
			if u.Path != path {
				continue
			}
			raw, err := json.Marshal(u.Value)
			if err != nil {
				t.Fatalf("marshal value at %s: %v", path, err)
			}
			var m map[string]any
			if err := json.Unmarshal(raw, &m); err != nil {
				t.Fatalf("value at %s is not an object: %v", path, err)
			}
			out = append(out, m)
		}
	}
	return out
}

func onlyUpdateAt(t *testing.T, np *NodePlan, path string) map[string]any {
	t.Helper()
	got := updatesAt(t, np, path)
	if len(got) != 1 {
		t.Fatalf("expected exactly one update at %s, got %d:\n%s", path, len(got), planJSON(t, np))
	}
	return got[0]
}

func planJSON(t *testing.T, np *NodePlan) string {
	t.Helper()
	b, err := json.MarshalIndent(np, "", "  ")
	if err != nil {
		t.Fatalf("marshal plan: %v", err)
	}
	return string(b)
}

func allPaths(np *NodePlan) []string {
	var out []string
	for _, op := range np.Ops {
		if op.GNMI == nil {
			continue
		}
		for _, u := range op.GNMI.Updates {
			out = append(out, u.Path)
		}
		out = append(out, op.GNMI.Deletes...)
	}
	return out
}

func hasCheck(np *NodePlan, typ, path, expect string) bool {
	for _, c := range np.Checks {
		if c.Type == typ && c.Path == path && c.Expect == expect {
			return true
		}
	}
	return false
}

func dig(t *testing.T, m map[string]any, keys ...string) any {
	t.Helper()
	var cur any = m
	for i, k := range keys {
		obj, ok := cur.(map[string]any)
		if !ok {
			t.Fatalf("path %v: %q is not an object at step %d", keys, k, i)
		}
		cur, ok = obj[k]
		if !ok {
			t.Fatalf("path %v: key %q absent at step %d (have %v)", keys, k, i, keysOf(obj))
		}
	}
	return cur
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// --- every op is a gNMI Set --------------------------------------------------

// The constitution's third principle: the only write path to the fabric is a
// gNMI Set. A plan that carried anything else would need a second primitive in
// the executor, and the docker/redis/vtysh southbound is exactly what this
// migration removes.
func TestEveryOpIsAGNMISet(t *testing.T) {
	for name, net := range map[string]*kubenet.Network{
		"vlan":    vlanNetwork(130),
		"mac-vrf": macVRFNetwork(150, 10150),
		"ip-vrf":  ipVRFNetwork(),
		"irb":     irbNetwork(),
		"acl":     aclNetwork(),
	} {
		plan, err := ForNetwork(net, Options{Ports: srlPorts()})
		if err != nil {
			t.Fatalf("%s: ForNetwork: %v", name, err)
		}
		for node, np := range plan.Nodes {
			for i, op := range append(append([]Op{}, np.Ops...), np.Rollback...) {
				if op.GNMI == nil {
					t.Errorf("%s/%s op %d is not a gNMI Set: %#v", name, node, i, op)
					continue
				}
				if len(op.GNMI.Updates) == 0 && len(op.GNMI.Deletes) == 0 {
					t.Errorf("%s/%s op %d is an empty gNMI Set", name, node, i)
				}
			}
			for i, c := range np.Checks {
				if !strings.HasPrefix(c.Type, "gnmi-") {
					t.Errorf("%s/%s check %d is not a gNMI check: %#v", name, node, i, c)
				}
				if c.Path == "" {
					t.Errorf("%s/%s check %d has no path: %#v", name, node, i, c)
				}
			}
		}
	}
}

// --- vlan --------------------------------------------------------------------

func vlanNetwork(vlan int64) *kubenet.Network {
	return &kubenet.Network{
		ObjectMeta: metav1.ObjectMeta{Name: "svc-vlan", Namespace: "acme"},
		Spec: map[string]any{
			"vlans":       []any{map[string]any{"name": "vlan-local", "vlan": float64(vlan)}},
			"attachments": []any{map[string]any{"node": "leaf01", "attachment": "ethernet1", "vlan": float64(vlan)}},
		},
	}
}

func TestVLANRendersLocalMacVRFOnly(t *testing.T) {
	plan, err := ForNetwork(vlanNetwork(130), Options{Ports: srlPorts()})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf01"]
	if np == nil {
		t.Fatal("leaf01 plan missing")
	}
	// A local vlan has no overlay: no vxlan-interface, no EVPN protocols.
	for _, p := range allPaths(np) {
		if strings.Contains(p, "tunnel-interface") {
			t.Errorf("local vlan touched the vxlan tunnel: %s", p)
		}
	}
	ni := onlyUpdateAt(t, np, "/network-instance[name=vlan-130]")
	if ni["type"] != "mac-vrf" {
		t.Errorf("local vlan network-instance is %v, want mac-vrf", ni["type"])
	}
	if _, ok := ni["protocols"]; ok {
		t.Errorf("local vlan declares EVPN protocols: %v", ni["protocols"])
	}
	if got := dig(t, ni, "interface"); !containsIfName(got, "ethernet-1/3.130") {
		t.Errorf("local vlan does not hold its attachment subinterface: %v", got)
	}

	sub := onlyUpdateAt(t, np, "/interface[name=ethernet-1/3]/subinterface[index=130]")
	if sub["type"] != "bridged" {
		t.Errorf("attachment subinterface is %v, want bridged", sub["type"])
	}
	if got := dig(t, sub, "vlan", "encap", "single-tagged", "vlan-id"); got != float64(130) {
		t.Errorf("attachment subinterface is not single-tagged 130: %v", got)
	}

	if !hasCheck(np, "gnmi-equals", "/network-instance[name=vlan-130]/oper-state", "up") ||
		!hasCheck(np, "gnmi-equals", "/interface[name=ethernet-1/3]/subinterface[index=130]/oper-state", "up") {
		t.Errorf("vlan checks missing:\n%s", planJSON(t, np))
	}

	wantRollback := []string{
		"/network-instance[name=vlan-130]",
		"/interface[name=ethernet-1/3]/subinterface[index=130]",
	}
	assertDeletes(t, np.Rollback, wantRollback)
}

func containsIfName(v any, want string) bool {
	list, ok := v.([]any)
	if !ok {
		return false
	}
	for _, item := range list {
		m, ok := item.(map[string]any)
		if ok && m["name"] == want {
			return true
		}
	}
	return false
}

func assertDeletes(t *testing.T, ops []Op, want []string) {
	t.Helper()
	var got []string
	for _, op := range ops {
		if op.GNMI == nil {
			continue
		}
		if len(op.GNMI.Updates) > 0 {
			t.Errorf("rollback op writes instead of deleting: %#v", op.GNMI.Updates)
		}
		got = append(got, op.GNMI.Deletes...)
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("rollback deletes\n  got:  %v\n  want: %v", got, want)
	}
}

// --- mac-vrf -----------------------------------------------------------------

func macVRFNetwork(vlan, l2vni int64) *kubenet.Network {
	return &kubenet.Network{
		ObjectMeta: metav1.ObjectMeta{Name: "svc-macvrf", Namespace: "blue"},
		Spec: map[string]any{
			"bridgeDomains": []any{map[string]any{
				"name": "bd-blue", "vlan": float64(vlan), "l2vni": float64(l2vni),
				"evpn": map[string]any{"routeTargets": map[string]any{"export": []any{"65000:5"}, "import": []any{"65000:5"}}},
			}},
			"attachments": []any{
				map[string]any{"node": "leaf01", "attachment": "ethernet1", "vlan": float64(vlan)},
				map[string]any{"node": "leaf02", "attachment": "ethernet1", "vlan": float64(vlan)},
			},
		},
	}
}

func TestMacVRFRendersOverlayOnBothLeaves(t *testing.T) {
	plan, err := ForNetwork(macVRFNetwork(150, 10150), Options{Ports: srlPorts()})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	if len(plan.Nodes) != 2 {
		t.Fatalf("expected a plan per leaf, got %d", len(plan.Nodes))
	}
	for _, node := range []string{"leaf01", "leaf02"} {
		np := plan.Nodes[node]
		if np == nil {
			t.Fatalf("%s plan missing", node)
		}
		vx := onlyUpdateAt(t, np, "/tunnel-interface[name=vxlan1]/vxlan-interface[index=10150]")
		if vx["type"] != "bridged" {
			t.Errorf("%s: vxlan-interface is %v, want bridged", node, vx["type"])
		}
		if got := dig(t, vx, "ingress", "vni"); got != float64(10150) {
			t.Errorf("%s: vxlan-interface ingress vni is %v", node, got)
		}
		if got := dig(t, vx, "egress", "source-ip"); got != "use-system-ipv4-address" {
			t.Errorf("%s: vxlan-interface egress source-ip is %v", node, got)
		}

		ni := onlyUpdateAt(t, np, "/network-instance[name=bd-blue]")
		if ni["type"] != "mac-vrf" {
			t.Errorf("%s: network-instance is %v, want mac-vrf", node, ni["type"])
		}
		if !containsIfName(ni["vxlan-interface"], "vxlan1.10150") {
			t.Errorf("%s: mac-vrf does not hold vxlan1.10150: %v", node, ni["vxlan-interface"])
		}
		evpn := dig(t, ni, "protocols", "bgp-evpn", "bgp-instance").([]any)[0].(map[string]any)
		if evpn["evi"] != float64(10150) {
			t.Errorf("%s: evi is %v, want the l2vni 10150", node, evpn["evi"])
		}
		if evpn["vxlan-interface"] != "vxlan1.10150" {
			t.Errorf("%s: bgp-evpn instance points at %v", node, evpn["vxlan-interface"])
		}
		vpn := dig(t, ni, "protocols", "bgp-vpn", "bgp-instance").([]any)[0].(map[string]any)
		if got := dig(t, vpn, "route-target", "export-rt"); got != "target:65000:5" {
			t.Errorf("%s: export-rt is %v, want the normalised target:65000:5", node, got)
		}

		// The only assertion self-origination cannot fake.
		found := false
		for _, c := range np.Checks {
			if c.Type == "gnmi-list-min" &&
				c.Path == "/tunnel-interface[name=vxlan1]/vxlan-interface[index=10150]/bridge-table/multicast-destinations/destination" &&
				c.MinCount == 1 {
				found = true
			}
		}
		if !found {
			t.Errorf("%s: no check proves a remote VTEP arrived:\n%s", node, planJSON(t, np))
		}

		assertDeletes(t, np.Rollback, []string{
			"/network-instance[name=bd-blue]",
			"/tunnel-interface[name=vxlan1]/vxlan-interface[index=10150]",
			"/interface[name=ethernet-1/3]/subinterface[index=150]",
		})
	}
}

// The allocator emits bare "65000:N"; SR Linux only accepts a typed RT.
func TestRouteTargetNormalisation(t *testing.T) {
	for in, want := range map[string]string{
		"65000:5":        "target:65000:5",
		"target:65000:5": "target:65000:5",
		"":               "",
	} {
		if got := normalizeRT(in); got != want {
			t.Errorf("normalizeRT(%q) = %q, want %q", in, got, want)
		}
	}
}

// SR Linux derives <system-ip>:<evi> when no route-distinguisher is configured,
// so an intent that declares none must not have one invented for it.
func TestRouteDistinguisherOmittedWhenIntentDeclaresNone(t *testing.T) {
	plan, err := ForNetwork(macVRFNetwork(150, 10150), Options{Ports: srlPorts()})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	ni := onlyUpdateAt(t, plan.Nodes["leaf01"], "/network-instance[name=bd-blue]")
	vpn := dig(t, ni, "protocols", "bgp-vpn", "bgp-instance").([]any)[0].(map[string]any)
	if rd, ok := vpn["route-distinguisher"]; ok {
		t.Errorf("route-distinguisher rendered from an intent that declares none: %v", rd)
	}

	// ...and it IS rendered when the intent carries one (the ip-vrf path).
	l3, err := ForNetwork(ipVRFNetwork(), Options{Ports: srlPorts()})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	vrf := onlyUpdateAt(t, l3.Nodes["leaf01"], "/network-instance[name=Vrf-initech01]")
	vpn = dig(t, vrf, "protocols", "bgp-vpn", "bgp-instance").([]any)[0].(map[string]any)
	if got := dig(t, vpn, "route-distinguisher", "rd"); got != "65000:18" {
		t.Errorf("rd is %v, want the intent's own 65000:18 (unprefixed)", got)
	}
}

// A bridgeDomain whose name is not a usable identifier still needs a stable
// device name, or apply, verify and rollback would each invent their own.
func TestBridgeNINameFallsBackToMacVRFVLAN(t *testing.T) {
	if got := DeviceBridgeNIName("bd-blue", 150); got != "bd-blue" {
		t.Errorf("DeviceBridgeNIName(bd-blue) = %q", got)
	}
	for _, bad := range []string{"", "1234", "///"} {
		if got := DeviceBridgeNIName(bad, 150); got != "macvrf-150" {
			t.Errorf("DeviceBridgeNIName(%q) = %q, want macvrf-150", bad, got)
		}
	}
}

// --- ip-vrf ------------------------------------------------------------------

func ipVRFNetwork() *kubenet.Network {
	return &kubenet.Network{
		ObjectMeta: metav1.ObjectMeta{Name: "svc-ipvrf", Namespace: "initech"},
		Spec: map[string]any{
			"routers": []any{map[string]any{
				"name": "vrf-initech01", "l3vni": float64(10018), "rd": "65000:18",
				"routeTargets": map[string]any{"import": []any{"65000:18"}, "export": []any{"65000:18"}},
				"prefixes":     []any{"10.50.0.0/24"},
			}},
			"attachments": []any{
				map[string]any{"node": "leaf01", "attachment": "wan1", "vrf": "vrf-initech01"},
				map[string]any{"node": "leaf02", "attachment": "wan1", "vrf": "vrf-initech01"},
			},
		},
	}
}

func TestIPVRFRendersRoutedAttachmentAndType5Check(t *testing.T) {
	plan, err := ForNetwork(ipVRFNetwork(), Options{Ports: srlPorts()})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf01"]
	tag, err := L3VLANForVNI(10018)
	if err != nil {
		t.Fatal(err)
	}
	if tag != 4018 {
		t.Fatalf("l3vni 10018 derives tag %d, want the pinned 4018", tag)
	}

	sub := onlyUpdateAt(t, np, "/interface[name=ethernet-1/4]/subinterface[index=4018]")
	if sub["type"] != "routed" {
		t.Errorf("ip-vrf attachment is %v, want routed", sub["type"])
	}
	if got := dig(t, sub, "vlan", "encap", "single-tagged", "vlan-id"); got != float64(4018) {
		t.Errorf("ip-vrf attachment tag is %v, want the derived 4018", got)
	}
	addr := dig(t, sub, "ipv4", "address").([]any)[0].(map[string]any)
	if addr["ip-prefix"] != "10.50.0.1/24" {
		t.Errorf("ip-vrf attachment address is %v, want the first host 10.50.0.1/24", addr["ip-prefix"])
	}

	vx := onlyUpdateAt(t, np, "/tunnel-interface[name=vxlan1]/vxlan-interface[index=10018]")
	if vx["type"] != "routed" {
		t.Errorf("ip-vrf vxlan-interface is %v, want routed", vx["type"])
	}

	ni := onlyUpdateAt(t, np, "/network-instance[name=Vrf-initech01]")
	if ni["type"] != "ip-vrf" {
		t.Errorf("network-instance is %v, want ip-vrf", ni["type"])
	}
	if !containsIfName(ni["interface"], "ethernet-1/4.4018") {
		t.Errorf("ip-vrf does not hold its attachment subinterface: %v", ni["interface"])
	}

	if !hasCheck(np, "gnmi-contains", type5Path, "10.50.0.0/24") {
		t.Errorf("no check proves the service prefix is originated as a Type-5:\n%s", planJSON(t, np))
	}
	assertDeletes(t, np.Rollback, []string{
		"/network-instance[name=Vrf-initech01]",
		"/tunnel-interface[name=vxlan1]/vxlan-interface[index=10018]",
		"/interface[name=ethernet-1/4]/subinterface[index=4018]",
	})
}

// EVI is the VNI on both overlay constructs: the contract pins it, and a
// mismatch between two leaves is a service that never forms.
func TestEVIEqualsVNI(t *testing.T) {
	l2, err := ForNetwork(macVRFNetwork(150, 10150), Options{Ports: srlPorts()})
	if err != nil {
		t.Fatal(err)
	}
	ni := onlyUpdateAt(t, l2.Nodes["leaf01"], "/network-instance[name=bd-blue]")
	if got := dig(t, ni, "protocols", "bgp-evpn", "bgp-instance").([]any)[0].(map[string]any)["evi"]; got != float64(10150) {
		t.Errorf("mac-vrf evi = %v, want 10150", got)
	}
	l3, err := ForNetwork(ipVRFNetwork(), Options{Ports: srlPorts()})
	if err != nil {
		t.Fatal(err)
	}
	vrf := onlyUpdateAt(t, l3.Nodes["leaf01"], "/network-instance[name=Vrf-initech01]")
	if got := dig(t, vrf, "protocols", "bgp-evpn", "bgp-instance").([]any)[0].(map[string]any)["evi"]; got != float64(10018) {
		t.Errorf("ip-vrf evi = %v, want 10018", got)
	}
}

func TestIPVRFRejectsInvalidPrefix(t *testing.T) {
	net := ipVRFNetwork()
	net.Spec["routers"].([]any)[0].(map[string]any)["prefixes"] = []any{"not-a-prefix"}
	if _, err := ForNetwork(net, Options{Ports: srlPorts()}); err == nil {
		t.Fatal("ForNetwork accepted an invalid service prefix")
	}
}

func TestFirstHostDerivation(t *testing.T) {
	for prefix, want := range map[string]string{
		"10.50.0.0/24":    "10.50.0.1/24",
		"10.0.0.7/24":     "10.0.0.1/24",
		"fd00:30::/64":    "fd00:30::1/64",
		"fd00:30::1/64":   "fd00:30::1/64",
		"192.0.2.5/32":    "192.0.2.5/32",
		"192.0.2.4/31":    "192.0.2.4/31",
		"2001:db8::1/128": "2001:db8::1/128",
	} {
		got, _, err := firstHost(prefix)
		if err != nil {
			t.Fatalf("firstHost(%q): %v", prefix, err)
		}
		if got != want {
			t.Errorf("firstHost(%q) = %q, want %q", prefix, got, want)
		}
	}
}

// --- IRB ---------------------------------------------------------------------

func irbNetwork() *kubenet.Network {
	return &kubenet.Network{
		ObjectMeta: metav1.ObjectMeta{Name: "svc-irb", Namespace: "green"},
		Spec: map[string]any{
			"bridgeDomains": []any{map[string]any{
				"name": "bd-irb1", "vlan": float64(200), "l2vni": float64(10005),
				"evpn": map[string]any{"routeTargets": map[string]any{"export": []any{"65000:5"}}},
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
		},
	}
}

// An IRB is L2 AND L3. Rendering only the L2 half silently hands the operator
// a VPLS with no gateway.
func TestIRBRendersBothHalves(t *testing.T) {
	plan, err := ForNetwork(irbNetwork(), Options{Ports: srlPorts()})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf01"]

	macvrf := onlyUpdateAt(t, np, "/network-instance[name=bd-irb1]")
	if !containsIfName(macvrf["interface"], "irb0.200") {
		t.Errorf("mac-vrf does not hold the gateway subinterface: %v", macvrf["interface"])
	}
	if !containsIfName(macvrf["interface"], "ethernet-1/3.200") {
		t.Errorf("mac-vrf does not hold the attachment subinterface: %v", macvrf["interface"])
	}

	irb := onlyUpdateAt(t, np, "/interface[name=irb0]/subinterface[index=200]")
	v4 := dig(t, irb, "ipv4", "address").([]any)[0].(map[string]any)
	if v4["ip-prefix"] != "10.30.0.1/24" || v4["anycast-gw"] != true {
		t.Errorf("IRB v4 gateway is not an anycast gateway: %v", v4)
	}
	v6 := dig(t, irb, "ipv6", "address").([]any)[0].(map[string]any)
	if v6["ip-prefix"] != "fd00:30::1/64" || v6["anycast-gw"] != true {
		t.Errorf("IRB v6 gateway is not an anycast gateway: %v", v6)
	}

	vrf := onlyUpdateAt(t, np, "/network-instance[name=Vrf-irb1]")
	if vrf["type"] != "ip-vrf" {
		t.Errorf("IRB routed half is %v, want ip-vrf", vrf["type"])
	}
	if !containsIfName(vrf["interface"], "irb0.200") {
		t.Errorf("ip-vrf does not own the gateway subinterface: %v", vrf["interface"])
	}
	// An IRB's routed attachment IS the gateway: no wan subinterface belongs in it.
	for _, p := range allPaths(np) {
		if strings.Contains(p, "ethernet-1/4") {
			t.Errorf("IRB rendered a wan attachment it was never asked for: %s", p)
		}
	}
	if !hasCheck(np, "gnmi-equals", "/interface[name=irb0]/subinterface[index=200]/oper-state", "up") {
		t.Errorf("no check proves the gateway subinterface is up:\n%s", planJSON(t, np))
	}
	// Both address families are originated: an IRB with a v6 gateway whose v6
	// prefix is never advertised is half a service.
	for _, want := range []string{"10.30.0.0/24", "fd00:30::/64"} {
		if !hasCheck(np, "gnmi-contains", type5Path, want) {
			t.Errorf("IRB does not verify Type-5 origination of %s:\n%s", want, planJSON(t, np))
		}
	}
}

func TestIRBWithoutItsRouterIsRejected(t *testing.T) {
	net := irbNetwork()
	delete(net.Spec, "routers")
	if _, err := ForNetwork(net, Options{Ports: srlPorts()}); err == nil {
		t.Fatal("ForNetwork rendered an IRB whose irb.vrf names no router")
	}
}

// --- acl ---------------------------------------------------------------------

func aclNetwork() *kubenet.Network {
	return &kubenet.Network{
		ObjectMeta: metav1.ObjectMeta{Name: "svc-acl", Namespace: "acme"},
		Spec: map[string]any{
			"accessLists": []any{map[string]any{
				"name": "allow-web", "stage": "ingress", "type": "l3", "defaultAction": "deny",
				"rules": []any{map[string]any{
					"name": "allow-https", "priority": float64(100), "action": "permit",
					"protocol": "tcp", "sourcePrefix": "10.0.0.0/24", "destinationPort": "443",
				}},
			}},
			"attachments": []any{map[string]any{"node": "leaf02", "attachment": "wan1"}},
		},
	}
}

func TestACLRendersFilterAndBinding(t *testing.T) {
	plan, err := ForNetwork(aclNetwork(), Options{Ports: srlPorts()})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf02"]
	if np == nil {
		t.Fatal("leaf02 plan missing")
	}
	table, err := DeviceACLTableName("svc-acl", "ingress")
	if err != nil {
		t.Fatal(err)
	}
	filterPath := "/acl/acl-filter[name=" + table + ",type=ipv4]"
	filter := onlyUpdateAt(t, np, filterPath)
	entries := dig(t, filter, "entry").([]any)
	if len(entries) != 2 {
		t.Fatalf("expected the declared rule plus the default entry, got %d: %v", len(entries), entries)
	}
	rule := entries[0].(map[string]any)
	if rule["sequence-id"] != float64(100) {
		t.Errorf("entry sequence-id is %v, want the rule's own priority 100", rule["sequence-id"])
	}
	if got := dig(t, rule, "match", "ipv4", "protocol"); got != "tcp" {
		t.Errorf("entry protocol is %v", got)
	}
	if got := dig(t, rule, "match", "ipv4", "source-ip", "prefix"); got != "10.0.0.0/24" {
		t.Errorf("entry source prefix is %v", got)
	}
	if got := dig(t, rule, "match", "transport", "destination-port", "value"); got != float64(443) {
		t.Errorf("entry destination port is %v", got)
	}
	if _, ok := dig(t, rule, "action").(map[string]any)["accept"]; !ok {
		t.Errorf("permit did not render as accept: %v", rule["action"])
	}
	// The default action is LAST: at a lower sequence-id it would shadow every
	// declared rule.
	def := entries[1].(map[string]any)
	if def["sequence-id"] != float64(aclDefaultSequence) {
		t.Errorf("default entry sequence-id is %v, want %d", def["sequence-id"], aclDefaultSequence)
	}
	if _, ok := dig(t, def, "action").(map[string]any)["drop"]; !ok {
		t.Errorf("deny default did not render as drop: %v", def["action"])
	}

	// An ACL-only Network has no service subinterface, so it binds on index 0.
	bind := onlyUpdateAt(t, np, "/interface[name=ethernet-1/4]/subinterface[index=0]/acl/input")
	entry := dig(t, bind, "acl-filter").([]any)[0].(map[string]any)
	if entry["name"] != table || entry["type"] != "ipv4" {
		t.Errorf("binding names %v", entry)
	}
	if !hasCheck(np, "gnmi-exists",
		"/interface[name=ethernet-1/4]/subinterface[index=0]/acl/input/acl-filter[name="+table+",type=ipv4]", "") {
		t.Errorf("no check proves the binding landed:\n%s", planJSON(t, np))
	}
	if !hasCheck(np, "gnmi-exists", filterPath+"/entry[sequence-id=100]/statistics", "") {
		t.Errorf("no applied-side check on the entry:\n%s", planJSON(t, np))
	}
	// Rollback unbinds before removing the filter: SR Linux refuses to delete a
	// filter that is still referenced.
	assertDeletes(t, np.Rollback, []string{
		"/interface[name=ethernet-1/4]/subinterface[index=0]/acl/input/acl-filter[name=" + table + ",type=ipv4]",
		filterPath,
	})
}

// An ACL declared alongside a service binds on that service's own
// subinterfaces, not on index 0: on SR Linux the filter attaches to a
// subinterface, so "the port" is not a precise enough binding point.
func TestACLBindsOnTheServiceSubinterfaces(t *testing.T) {
	net := macVRFNetwork(150, 10150)
	net.ObjectMeta = metav1.ObjectMeta{Name: "svc-macvrf-acl", Namespace: "blue"}
	net.Spec["accessLists"] = []any{map[string]any{
		"name": "deny-egress", "stage": "egress", "type": "l3v6",
		"rules": []any{map[string]any{"name": "deny", "priority": float64(200), "action": "deny", "sourcePrefix": "fd00::/8"}},
	}}
	plan, err := ForNetwork(net, Options{Ports: srlPorts()})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	table, err := DeviceACLTableName("svc-macvrf-acl", "egress")
	if err != nil {
		t.Fatal(err)
	}
	for _, node := range []string{"leaf01", "leaf02"} {
		np := plan.Nodes[node]
		if len(updatesAt(t, np, "/interface[name=ethernet-1/3]/subinterface[index=150]/acl/output")) != 1 {
			t.Errorf("%s: egress ACL is not bound on the service subinterface:\n%s", node, planJSON(t, np))
		}
		if len(updatesAt(t, np, "/interface[name=ethernet-1/3]/subinterface[index=0]/acl/output")) != 0 {
			t.Errorf("%s: egress ACL bound on subinterface 0 of a service that has its own", node)
		}
		if got := updatesAt(t, np, "/acl/acl-filter[name="+table+",type=ipv6]"); len(got) != 1 {
			t.Errorf("%s: l3v6 access list did not render an ipv6 filter:\n%s", node, planJSON(t, np))
		}
	}
}

func TestACLRefusesICMPv6(t *testing.T) {
	net := aclNetwork()
	net.Spec["accessLists"].([]any)[0].(map[string]any)["rules"].([]any)[0].(map[string]any)["protocol"] = "icmpv6"
	_, err := ForNetwork(net, Options{Ports: srlPorts()})
	if err == nil {
		t.Fatal("ForNetwork accepted an icmpv6 match")
	}
	if !strings.Contains(err.Error(), "icmpv6") {
		t.Errorf("refusal does not name the protocol: %v", err)
	}
}

func TestACLOnlyNetworkWithNoAttachmentsIsRefused(t *testing.T) {
	net := aclNetwork()
	net.Spec["attachments"] = []any{}
	if _, err := ForNetwork(net, Options{Ports: srlPorts()}); err == nil {
		t.Fatal("expected error for an ACL-only network with no attachments")
	}
}

// --- refusals ----------------------------------------------------------------

func TestUnknownPortIsRefusedNamingTheSitesPorts(t *testing.T) {
	net := vlanNetwork(130)
	net.Spec["attachments"].([]any)[0].(map[string]any)["attachment"] = "ethernet9"
	_, err := ForNetwork(net, Options{Ports: srlPorts()})
	if err == nil {
		t.Fatal("ForNetwork accepted a port the site does not have")
	}
	if !strings.Contains(err.Error(), "ethernet1") || !strings.Contains(err.Error(), "wan1") {
		t.Errorf("refusal does not name the site's ports: %v", err)
	}
}

func TestPortMapperFoldsSpelling(t *testing.T) {
	m := srlPorts()
	for _, spelling := range []string{"ethernet1", "Ethernet1", "ETHERNET1", "ethernet-1", "Ethernet_1"} {
		got, err := m.Port(spelling)
		if err != nil {
			t.Errorf("Port(%q): %v", spelling, err)
			continue
		}
		if got != "ethernet-1/3" {
			t.Errorf("Port(%q) = %q, want ethernet-1/3", spelling, got)
		}
	}
	if _, err := m.Port("ethernet9"); err == nil {
		t.Fatal("Port accepted a port the site does not have")
	}
}

func TestEmptyPortMapIsRefused(t *testing.T) {
	if _, err := ForNetwork(vlanNetwork(130), Options{}); err == nil {
		t.Fatal("ForNetwork rendered against a site with no port map")
	}
}

func TestServiceVLANInDerivedBandIsRefused(t *testing.T) {
	if _, err := ForNetwork(macVRFNetwork(4007, 10004), Options{Ports: srlPorts()}); err == nil {
		t.Fatal("ForNetwork accepted a service vlan inside the derived-tag band")
	}
	if _, err := ForNetwork(vlanNetwork(4007), Options{Ports: srlPorts()}); err == nil {
		t.Fatal("ForNetwork accepted a local vlan inside the derived-tag band")
	}
}

func TestAttachmentVLANWithNoBridgeDomainNamesWhatExists(t *testing.T) {
	net := macVRFNetwork(150, 10150)
	net.Spec["attachments"].([]any)[1].(map[string]any)["vlan"] = float64(151)
	_, err := ForNetwork(net, Options{Ports: srlPorts()})
	if err == nil {
		t.Fatal("ForNetwork accepted an attachment on a vlan no bridgeDomain declares")
	}
	if !strings.Contains(err.Error(), "vlan 150") {
		t.Errorf("rejection does not name the vlan that does exist: %v", err)
	}
}

func TestAttachmentWithUnknownRouterIsRefused(t *testing.T) {
	net := ipVRFNetwork()
	net.Spec["attachments"].([]any)[0].(map[string]any)["vrf"] = "vrf-nonexistent"
	if _, err := ForNetwork(net, Options{Ports: srlPorts()}); err == nil {
		t.Fatal("ForNetwork accepted an attachment naming no router")
	}
}

func TestAttachmentWithNeitherVRFNorVLANIsRefused(t *testing.T) {
	net := &kubenet.Network{Spec: map[string]any{
		"attachments": []any{map[string]any{"node": "leaf01", "attachment": "wan1"}},
	}}
	if _, err := ForNetwork(net, Options{Ports: srlPorts()}); err == nil {
		t.Fatal("ForNetwork accepted an attachment with no service on it")
	}
}

// TestL3VLANForVNIStaysInBand pins the fold. A straight offset walked out of
// the 12-bit tag space (l3vni 10250 produced 4250, not a valid vlan-id).
func TestL3VLANForVNIStaysInBand(t *testing.T) {
	for vni := evpnVNIMin; vni <= evpnVNIMax; vni++ {
		got, err := L3VLANForVNI(vni)
		if err != nil {
			t.Fatalf("L3VLANForVNI(%d): unexpected error %v", vni, err)
		}
		if got <= l3VLANBase || got > 4094 {
			t.Fatalf("L3VLANForVNI(%d) = %d, outside the reserved %d-4094 band", vni, got, l3VLANBase+1)
		}
	}
	if _, err := L3VLANForVNI(evpnVNIMin - 1); err == nil {
		t.Error("L3VLANForVNI accepted an l3vni below the evpn-vni range")
	}
	if _, err := L3VLANForVNI(evpnVNIMax + 1); err == nil {
		t.Error("L3VLANForVNI accepted an l3vni above the evpn-vni range")
	}
	if got, _ := L3VLANForVNI(10250); got == 4250 {
		t.Fatal("l3vni 10250 still derives the out-of-range tag 4250")
	}
}

// TestCollidingL3VNIsAreRefused covers the cost of folding: two l3vnis exactly
// one band apart derive the same tag, which would put two VRFs on one
// attachment subinterface.
func TestCollidingL3VNIsAreRefused(t *testing.T) {
	net := &kubenet.Network{Spec: map[string]any{
		"routers": []any{
			map[string]any{"name": "vrf-a", "l3vni": float64(10010), "prefixes": []any{"10.0.0.0/24"}},
			map[string]any{"name": "vrf-b", "l3vni": float64(10010 + l3VLANBandSize), "prefixes": []any{"10.1.0.0/24"}},
		},
		"attachments": []any{map[string]any{"node": "leaf01", "attachment": "wan1", "vrf": "vrf-a"}},
	}}
	_, err := ForNetwork(net, Options{Ports: srlPorts()})
	if err == nil {
		t.Fatal("ForNetwork accepted two l3vnis that derive the same L3VLAN")
	}
	if !strings.Contains(err.Error(), "derive L3VLAN") {
		t.Errorf("error does not explain the collision: %v", err)
	}
}

func TestRouterWithoutL3VNIIsRefused(t *testing.T) {
	net := ipVRFNetwork()
	delete(net.Spec["routers"].([]any)[0].(map[string]any), "l3vni")
	if _, err := ForNetwork(net, Options{Ports: srlPorts()}); err == nil {
		t.Fatal("ForNetwork rendered a router with no l3vni")
	}
}

func TestBridgeDomainWithoutL2VNIIsRefused(t *testing.T) {
	net := macVRFNetwork(150, 10150)
	delete(net.Spec["bridgeDomains"].([]any)[0].(map[string]any), "l2vni")
	if _, err := ForNetwork(net, Options{Ports: srlPorts()}); err == nil {
		t.Fatal("ForNetwork rendered a mac-vrf with no l2vni")
	}
}

// The renderer is the only thing standing between a reconcile loop and the
// fabric, so the same intent must render byte-identically every time.
func TestRenderIsDeterministic(t *testing.T) {
	for name, build := range map[string]func() *kubenet.Network{
		"vlan":    func() *kubenet.Network { return vlanNetwork(130) },
		"mac-vrf": func() *kubenet.Network { return macVRFNetwork(150, 10150) },
		"ip-vrf":  ipVRFNetwork,
		"irb":     irbNetwork,
		"acl":     aclNetwork,
	} {
		var first string
		for i := 0; i < 5; i++ {
			plan, err := ForNetwork(build(), Options{Ports: srlPorts()})
			if err != nil {
				t.Fatalf("%s: ForNetwork: %v", name, err)
			}
			b, err := json.Marshal(plan.Nodes)
			if err != nil {
				t.Fatalf("%s: marshal: %v", name, err)
			}
			if i == 0 {
				first = string(b)
				continue
			}
			if string(b) != first {
				t.Fatalf("%s: render is not deterministic across calls", name)
			}
		}
	}
}
