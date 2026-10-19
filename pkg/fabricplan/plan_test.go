// SPDX-License-Identifier: Apache-2.0
package fabricplan

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

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

// --- per-kind construct parity (spec 004 plan 4-05..4-19) ---------------------
//
// The p4-*-trial proofs apply each construct's rendered plan to the sonic-vm
// lab through the fabric-executor and record every op that fails or behaves
// differently. These per-kind cases pin exactly what those trials showed the
// sonic-vm guest needs. The sonic-vs cases above are unchanged: sonic-vs
// output stays byte-identical across this whole effort (FR-040).

// vmPortMap is the sonic-vm profile's logical attachment -> guest port map
// (lab/profiles/sonic-vm/port-map.json), the same map the p4-*-trial proofs
// render with. eth3 is the guest's client access port (Ethernet8).
var vmPortMap = PortMapper{
	"wan1": "Ethernet12", "ethernet1": "Ethernet8", "ethernet2": "Ethernet4",
	"eth1": "Ethernet0", "eth2": "Ethernet4", "eth3": "Ethernet8", "eth4": "Ethernet12",
}

func opsStrings(np *NodePlan) []string {
	var out []string
	for i, op := range np.Ops {
		for _, r := range op.Redis {
			out = append(out, fmt.Sprintf("ops[%d].redis: %s", i, r))
		}
		for _, s := range op.Shell {
			out = append(out, fmt.Sprintf("ops[%d].shell: %s", i, s))
		}
		for _, g := range op.GCU {
			out = append(out, fmt.Sprintf("ops[%d].gcu: %s", i, g))
		}
		for _, c := range op.FRRConf {
			out = append(out, fmt.Sprintf("ops[%d].frrconf: %s", i, c))
		}
	}
	return out
}

// The p4-vlan-trial proof (scripts/spike/networks/vlan.yaml on the sonic-vm
// lab) showed ZERO diffs: the vlan construct's ops apply and verify
// identically over the SSH transport, and the rollback cleans up. This case
// pins that parity: for the vm kind the guest needs the same ops the trial
// applied (VLAN row + Bridge membership on the guest port name), and the
// sonic-vs rendering is byte-identical to what it always was.
func TestVLANPlanPerKind_VMNeedsWhatTheTrialApplied(t *testing.T) {
	net := &kubenet.Network{Spec: map[string]any{
		"vlans":       []any{map[string]any{"name": "p4-trial-vlan", "vlan": float64(3500)}},
		"attachments": []any{map[string]any{"node": "leaf01", "attachment": "eth3", "vlan": float64(3500)}},
	}}
	vm, err := ForNetwork(net, Options{Ports: vmPortMap, NodeKind: "sonic-vm"})
	if err != nil {
		t.Fatalf("sonic-vm ForNetwork: %v", err)
	}
	np := vm.Nodes["leaf01"]
	if np == nil {
		t.Fatal("leaf01 plan missing")
	}
	got := strings.Join(opsStrings(np), "\n")
	// Exactly the ops p4-vlan-trial applied and verified on the guest.
	want := []string{
		"ops[0].redis: hset 'VLAN|Vlan3500' vlanid '3500'",
		"ops[1].shell: ip link show Bridge >/dev/null 2>&1 || { ip link add Bridge type bridge; ip link set Bridge up; }",
		"ops[1].shell: ip link show Ethernet8 | grep -q 'master Bridge' || { ip link set Ethernet8 nomaster 2>/dev/null || true; ip link set Ethernet8 master Bridge; }",
		"ops[1].shell: bridge vlan del dev Ethernet8 vid 1 2>/dev/null || true",
		"ops[1].shell: if bridge vlan show dev Ethernet8 2>/dev/null | grep -qw PVID; then bridge vlan add dev Ethernet8 vid 3500 2>/dev/null || true; else bridge vlan add dev Ethernet8 vid 3500 pvid untagged 2>/dev/null || true; fi",
		"ops[1].shell: ip link set Ethernet8 up 2>/dev/null || true",
	}
	if got != strings.Join(want, "\n") {
		t.Fatalf("sonic-vm vlan plan differs from the ops p4-vlan-trial applied:\n got:\n%s\nwant:\n%s", got, strings.Join(want, "\n"))
	}
	// And the checks the trial verified hold on the guest.
	for _, wantCK := range []Check{
		{Type: "redis-hget", RedisKey: "VLAN|Vlan3500", RedisField: "vlanid", Expect: "3500"},
		{Type: "ip-master", Iface: "Ethernet8", Master: "Bridge"},
		{Type: "bridge-vid", Iface: "Ethernet8", Vid: 3500},
	} {
		found := false
		for _, ck := range np.Checks {
			if ck.Type == wantCK.Type && ck.RedisKey == wantCK.RedisKey && ck.RedisField == wantCK.RedisField &&
				ck.Expect == wantCK.Expect && ck.Iface == wantCK.Iface && ck.Master == wantCK.Master && ck.Vid == wantCK.Vid {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("sonic-vm vlan plan missing trial check %s (%#v)", wantCK.Type, wantCK)
		}
	}

	// Parity: with the same logical attachment resolved to the same guest
	// port, the vs and vm renderings are byte-identical — the vm kind needed
	// no different ops for vlan, exactly what the trial recorded.
	vs, err := ForNetwork(net, Options{Ports: PortMapper{"eth3": "Ethernet8"}, NodeKind: "sonic-vs"})
	if err != nil {
		t.Fatalf("sonic-vs ForNetwork: %v", err)
	}
	if gotVS := strings.Join(opsStrings(vs.Nodes["leaf01"]), "\n"); gotVS != got {
		t.Fatalf("sonic-vs vlan output drifted from sonic-vm parity:\nvs:\n%s\nvm:\n%s", gotVS, got)
	}
}

// --- VLAN (local) ------------------------------------------------------------

func TestVLANPlanRendersLocalOnly_NoVXLANOrEVPN(t *testing.T) {
	net := &kubenet.Network{Spec: map[string]any{
		"vlans":       []any{map[string]any{"name": "vlan-local", "vlan": float64(120)}},
		"attachments": []any{map[string]any{"node": "leaf01", "attachment": "ethernet1", "vlan": float64(120)}},
	}}
	plan, err := ForNetwork(net, Options{Ports: PortMapper{"ethernet1": "eth3"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf01"]
	if np == nil {
		t.Fatal("leaf01 plan missing")
	}
	// No VXLAN_TUNNEL_MAP rows and no vtep device handling, no l2vpn evpn block.
	for _, op := range np.Ops {
		for _, r := range op.Redis {
			if strings.Contains(r, "VXLAN_TUNNEL_MAP|") {
				t.Fatalf("local VLAN emitted a VXLAN_TUNNEL_MAP row: %q", r)
			}
		}
		for _, s := range op.Shell {
			if strings.Contains(s, "vtep1-") || strings.Contains(s, "address-family l2vpn evpn") {
				t.Fatalf("local VLAN touched vtep or l2vpn evpn: %q", s)
			}
		}
	}
	// Positive: VLAN row and access port membership with bridge vid check exist.
	foundVLANRow := false
	foundBridgeVID := false
	for _, ck := range np.Checks {
		if ck.Type == "redis-hget" && strings.Contains(ck.RedisKey, "VLAN|Vlan120") && ck.RedisField == "vlanid" && ck.Expect == "120" {
			foundVLANRow = true
		}
		if ck.Type == "bridge-vid" && ck.Iface == "eth3" && ck.Vid == 120 {
			foundBridgeVID = true
		}
	}
	if !foundVLANRow || !foundBridgeVID {
		t.Fatalf("local VLAN checks missing: %#v", np.Checks)
	}
}

// --- L2 ----------------------------------------------------------------------

// The p4-macvrf-trial proof (scripts/spike/networks/macvrf.yaml on the
// sonic-vm lab) found the guest with NO site overlay baseline: no
// VXLAN_TUNNEL|vtep1 row, no EVPN_NVO|nvo1. vxlanmgrd therefore never built
// vtep1-3501: the plan's wait loop exited 1 and every VTEP-dependent check
// failed (ip-master/bridge-vid on vtep1-3501, link-vxlan-id, EVPN VNI). The
// sonic-vs bootstrap configures that baseline (configure_overlay); the
// sonic-vm profile does not, so a mac-vrf plan for the vm kind must ensure it
// idempotently before its tunnel-map row. The vs rendering stays untouched.
func TestMACVRFPlanPerKind_VMGuestNeedsItsVTEPBaseline(t *testing.T) {
	net := l2NetworkVM(3501, 13501)
	vm, err := ForNetwork(net, Options{Ports: vmPortMap, NodeKind: "sonic-vm"})
	if err != nil {
		t.Fatalf("sonic-vm ForNetwork: %v", err)
	}
	np := vm.Nodes["leaf01"]
	if np == nil || len(np.Ops) == 0 {
		t.Fatal("leaf01 plan missing")
	}
	// FIRST op: the vm-only VTEP baseline, idempotent, source from Loopback0
	// (the same source the vs bootstrap writes), before any tunnel-map row.
	first := np.Ops[0]
	if len(first.Shell) != 1 || len(first.Redis) != 0 {
		t.Fatalf("sonic-vm mac-vrf plan must start with the VTEP baseline shell op, got %#v", first)
	}
	base := first.Shell[0]
	for _, needle := range []string{
		"Loopback0", "VXLAN_TUNNEL|vtep1", "src_ip", "EVPN_NVO|nvo1", "source_vtep",
	} {
		if !strings.Contains(base, needle) {
			t.Fatalf("sonic-vm VTEP baseline op missing %q:\n%s", needle, base)
		}
	}
	// Then the long-standing overlay: redis rows, kernel shell, EVPN block.
	overlayRows := strings.Join(np.Ops[1].Redis, "\n")
	if len(np.Ops) < 4 || !strings.Contains(overlayRows, "VXLAN_TUNNEL_MAP|vtep1|map_13501_Vlan3501") ||
		!strings.Contains(overlayRows, "VLAN|Vlan3501") {
		t.Fatalf("sonic-vm mac-vrf plan lost its overlay rows after the baseline: %#v", np.Ops[1])
	}
	if !strings.Contains(allShell(np), "vni 13501") && !strings.Contains(allShell(np), "vtep1-3501") {
		t.Fatalf("sonic-vm mac-vrf plan lost its vtep shell:\n%s", allShell(np))
	}
	// The EVPN op must speak the guest's dialect (p4-macvrf-trial-healed):
	// this FRR build accepts per-VNI rd/route-target only once the default
	// instance advertises all VNIs, and its durable FRR config lives at
	// /etc/sonic/frr/bgpd.conf — /etc/frr/bgpd.conf does not exist there.
	evpn := ""
	for _, op := range np.Ops {
		for _, s := range op.Shell {
			if strings.Contains(s, "address-family l2vpn evpn") {
				evpn += s + "\n"
			}
		}
	}
	if evpn == "" {
		t.Fatal("sonic-vm mac-vrf plan has no EVPN op")
	}
	if !strings.Contains(evpn, "advertise-all-vni") {
		t.Fatalf("sonic-vm EVPN op must enable advertise-all-vni before per-VNI rd/route-target:\n%s", evpn)
	}
	if !strings.Contains(evpn, "/etc/sonic/frr/bgpd.conf") {
		t.Fatalf("sonic-vm EVPN op must append to /etc/sonic/frr/bgpd.conf:\n%s", evpn)
	}
	if strings.Contains(evpn, "/etc/frr/bgpd.conf") {
		t.Fatalf("sonic-vm EVPN op still targets the vs conf path /etc/frr/bgpd.conf:\n%s", evpn)
	}
	// The baseline op is NOT rolled back: the managers/bootstrap own those rows.
	for _, rb := range np.Rollback {
		for _, s := range rb.Shell {
			if strings.Contains(s, "VXLAN_TUNNEL|vtep1") {
				t.Fatalf("rollback deletes the VTEP baseline the bootstrap owns: %q", s)
			}
		}
	}

	// sonic-vs: same intent, same port map — NO baseline op (byte-identical
	// to the long-standing vs rendering, FR-040).
	vs, err := ForNetwork(net, Options{Ports: vmPortMap, NodeKind: "sonic-vs"})
	if err != nil {
		t.Fatalf("sonic-vs ForNetwork: %v", err)
	}
	if len(vs.Nodes["leaf01"].Ops) == 0 {
		t.Fatal("vs plan missing")
	}
	vsFirst := vs.Nodes["leaf01"].Ops[0]
	if len(vsFirst.Redis) == 0 || len(vsFirst.Shell) != 0 {
		t.Fatalf("sonic-vs mac-vrf rendering changed: first op must stay the redis overlay, got %#v", vsFirst)
	}
	if strings.Contains(allShell(vs.Nodes["leaf01"]), "Loopback0") {
		t.Fatal("sonic-vs rendering gained the vm VTEP baseline; vs output must stay byte-identical")
	}
	// And the vs EVPN op keeps its own dialect: no advertise-all-vni, vs conf
	// path.
	vsEVPN := allShell(vs.Nodes["leaf01"])
	if !strings.Contains(vsEVPN, "address-family l2vpn evpn") || !strings.Contains(vsEVPN, "/etc/frr/bgpd.conf") {
		t.Fatalf("sonic-vs EVPN op changed:\n%s", vsEVPN)
	}
	if strings.Contains(vsEVPN, "advertise-all-vni") || strings.Contains(vsEVPN, "/etc/sonic/frr/bgpd.conf") {
		t.Fatalf("sonic-vs EVPN op gained vm dialect; vs output must stay byte-identical:\n%s", vsEVPN)
	}
}

// l2NetworkVM is l2Network with the sonic-vm guest's client access port key.
func l2NetworkVM(vlan int64, l2vni int64) *kubenet.Network {
	return &kubenet.Network{Spec: map[string]any{
		"bridgeDomains": []any{map[string]any{
			"name": "bd-vm1", "vlan": float64(vlan), "l2vni": float64(l2vni),
			"evpn": map[string]any{"routeTargets": map[string]any{"export": []any{"65000:13501"}}},
		}},
		"attachments": []any{
			map[string]any{"node": "leaf01", "attachment": "eth3", "vlan": float64(vlan)},
			map[string]any{"node": "leaf02", "attachment": "eth3", "vlan": float64(vlan)},
		},
	}}
}

// The p4-ipvrf-trial proof (scripts/spike/networks/ipvrf.yaml) converged with
// ZERO diffs — but it ran on a lab that already carried the VTEP baseline the
// healed mac-vrf trial left behind (plans never roll back manager-owned rows).
// On a fresh sonic-vm lab the L3VNI's VXLAN_TUNNEL_MAP row cannot build
// vtep1-<l3vlan> without VXLAN_TUNNEL|vtep1 + EVPN_NVO|nvo1 — the same root
// cause the mac-vrf trial proved. The vm ip-vrf plan must ensure the baseline
// itself; the vs rendering stays byte-identical.
func TestIPVRFPlanPerKind_VMGuestNeedsItsVTEPBaseline(t *testing.T) {
	net := &kubenet.Network{Spec: map[string]any{
		"routers": []any{map[string]any{
			"name": "p4-trial-ipvrf", "l3vni": float64(13518), "rd": "65000:18",
			"routeTargets": map[string]any{"import": []any{"65000:18"}, "export": []any{"65000:18"}},
			"prefixes":     []any{"10.199.0.0/24"},
		}},
		"attachments": []any{
			map[string]any{"node": "leaf01", "attachment": "wan1", "vrf": "p4-trial-ipvrf"},
		},
	}}
	vm, err := ForNetwork(net, Options{Ports: vmPortMap, NodeKind: "sonic-vm"})
	if err != nil {
		t.Fatalf("sonic-vm ForNetwork: %v", err)
	}
	np := vm.Nodes["leaf01"]
	if np == nil || len(np.Ops) == 0 {
		t.Fatal("leaf01 plan missing")
	}
	first := np.Ops[0]
	if len(first.Shell) != 1 || len(first.Redis) != 0 || len(first.GCU) != 0 {
		t.Fatalf("sonic-vm ip-vrf plan must start with the VTEP baseline shell op, got %#v", first)
	}
	base := first.Shell[0]
	for _, needle := range []string{"Loopback0", "VXLAN_TUNNEL|vtep1", "EVPN_NVO|nvo1"} {
		if !strings.Contains(base, needle) {
			t.Fatalf("sonic-vm ip-vrf VTEP baseline op missing %q:\n%s", needle, base)
		}
	}
	// Then the long-standing flow: VRF row, L3VLAN row + tunnel map, kernel.
	if len(np.Ops) < 4 || len(np.Ops[1].GCU) == 0 {
		t.Fatalf("sonic-vm ip-vrf plan lost its VRF GCU row after the baseline: %#v", np.Ops[1])
	}
	allRows := allShell(np)
	for _, op := range np.Ops {
		allRows += strings.Join(op.Redis, "\n")
	}
	if !strings.Contains(allRows, "VXLAN_TUNNEL_MAP|vtep1|map_13518_") {
		t.Fatalf("sonic-vm ip-vrf plan lost its L3VNI tunnel map row:\n%s", allRows)
	}

	// sonic-vs: first op stays the VRF GCU row — no baseline op.
	vs, err := ForNetwork(net, Options{Ports: vmPortMap, NodeKind: "sonic-vs"})
	if err != nil {
		t.Fatalf("sonic-vs ForNetwork: %v", err)
	}
	vsFirst := vs.Nodes["leaf01"].Ops[0]
	if len(vsFirst.GCU) == 0 || len(vsFirst.Shell) != 0 {
		t.Fatalf("sonic-vs ip-vrf rendering changed: first op must stay the VRF GCU row, got %#v", vsFirst)
	}
}

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
	// The L3VNI tunnel map is written from the shell op, after sviShell has
	// created Vlan4006: vxlanmgrd only attempts the vtep build once, so the row
	// must not land before the VLAN device exists.
	joinedShell := allShell(np)
	if !strings.Contains(joinedShell, "map_10006_Vlan4006") {
		t.Errorf("IRB plan is missing the L3VNI tunnel map:\n%s", joinedShell)
	}
	if strings.Contains(joinedRedis, "map_10006_Vlan4006") {
		t.Errorf("L3VNI tunnel map is still written before its SVI exists:\n%s", joinedRedis)
	}
	if idx, mapIdx := strings.Index(joinedShell, "ip link add Vlan4006"), strings.Index(joinedShell, "map_10006_Vlan4006"); idx >= 0 && mapIdx >= 0 && mapIdx < idx {
		t.Error("tunnel map is written before the SVI is created")
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

// --- ACL (US2) ----------------------------------------------------------------

func TestACLPlan_RendersRedisOnly_WithDefaultRuleAndChecks_NoGCU(t *testing.T) {
	// Strengthened per-rule config-side assertions: assert PRIORITY, PACKET_ACTION,
	// IP_PROTOCOL and L4_DST_PORT checks are present for declared fields.

	// Build a Network with accessLists and attachments only (ACL-only service)
	net := &kubenet.Network{
		ObjectMeta: metav1.ObjectMeta{Name: "svc-acl", Namespace: "tenant-a"},
		Spec: map[string]any{
			"accessLists": []any{map[string]any{
				"name":          "allow-web",
				"stage":         "ingress",
				"type":          "l3",
				"defaultAction": "deny",
				"rules": []any{map[string]any{
					"name": "allow-https", "priority": float64(100), "action": "permit", "protocol": "tcp", "destinationPort": "443",
				}},
			}},
			"attachments": []any{map[string]any{"node": "leaf01", "attachment": "ethernet1"}},
		},
	}
	plan, err := ForNetwork(net, Options{Ports: PortMapper{"ethernet1": "eth3"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf01"]
	if np == nil {
		t.Fatal("leaf01 plan missing")
	}
	// Assert no GCU ops were emitted for ACL
	for _, op := range np.Ops {
		if len(op.GCU) > 0 {
			t.Fatalf("ACL plan must not use GCU ops: %#v", op.GCU)
		}
	}
	// Collect redis ops
	var redis [][]string
	for _, op := range np.Ops {
		if len(op.Redis) > 0 {
			redis = append(redis, op.Redis)
		}
	}
	// Expect table and rule rows, including default rule with PRIORITY 1
	var haveTable, haveRule, haveDefault bool
	for _, cmds := range redis {
		joined := strings.Join(cmds, "\n")
		if strings.Contains(joined, "ACL_TABLE|") {
			if !strings.Contains(joined, "stage '") || !strings.Contains(joined, "type '") || !strings.Contains(joined, "ports@ '") {
				t.Errorf("ACL_TABLE missing required fields: %s", joined)
			}
			haveTable = true
		}
		if strings.Contains(joined, "ACL_RULE|") && strings.Contains(joined, "PRIORITY '100'") {
			haveRule = true
		}
		if strings.Contains(joined, "ACL_RULE|") && strings.Contains(joined, "|default' PRIORITY '1'") {
			haveDefault = true
		}
	}
	if !haveTable || !haveRule || !haveDefault {
		t.Fatalf("missing expected ACL rows: table=%v rule=%v default=%v", haveTable, haveRule, haveDefault)
	}
	// Configuration-side checks include redis-exists/hget on table and rules, and redis-hget-contains on ports@
	var haveCfgChecks, haveAppliedTable, haveAppliedEntries bool
	var tableStageOK, tableBindOK bool
	var entriesMinOK bool
	for _, ck := range np.Checks {
		if ck.Type == "redis-exists" || ck.Type == "redis-hget" || ck.Type == "redis-hget-contains" {
			haveCfgChecks = true
		}
		if ck.Type == "redis-keys-match" && ck.RedisDB == "1" && strings.HasPrefix(ck.RedisKey, "ASIC_STATE:SAI_OBJECT_TYPE_ACL_TABLE:") {
			haveAppliedTable = true
			// stage must match ingress and bind point must be port
			if ck.MatchFields != nil {
				if ck.MatchFields["SAI_ACL_TABLE_ATTR_ACL_STAGE"] == "SAI_ACL_STAGE_INGRESS" {
					tableStageOK = true
				}
				if ck.MatchFields["SAI_ACL_TABLE_ATTR_ACL_BIND_POINT_TYPE_LIST"] == "SAI_ACL_BIND_POINT_TYPE_PORT" {
					tableBindOK = true
				}
			}
		}
		if ck.Type == "redis-keys-match" && ck.RedisDB == "1" && strings.HasPrefix(ck.RedisKey, "ASIC_STATE:SAI_OBJECT_TYPE_ACL_ENTRY:") {
			haveAppliedEntries = true
			// 1 declared rule + 1 defaultAction
			if ck.MinCount == 2 {
				entriesMinOK = true
			}
		}
	}
	if !haveCfgChecks || !haveAppliedTable || !haveAppliedEntries || !tableStageOK || !tableBindOK || !entriesMinOK {
		t.Fatalf("missing expected checks or attributes: cfg=%v asicTable=%v asicEntries=%v stageOK=%v bindOK=%v entriesMinOK=%v", haveCfgChecks, haveAppliedTable, haveAppliedEntries, tableStageOK, tableBindOK, entriesMinOK)
	}
	// Assert per-rule config-side checks: PRIORITY=100, PACKET_ACTION=FORWARD, IP_PROTOCOL=6, L4_DST_PORT=443
	havePriority := false
	havePacket := false
	haveProto := false
	haveDstPort := false
	for _, ck := range np.Checks {
		if ck.Type == "redis-hget" && strings.Contains(ck.RedisKey, "ACL_RULE|") {
			switch ck.RedisField {
			case "PRIORITY":
				if ck.Expect == "100" {
					havePriority = true
				}
			case "PACKET_ACTION":
				if ck.Expect == "FORWARD" {
					havePacket = true
				}
			case "IP_PROTOCOL":
				if ck.Expect == "6" {
					haveProto = true
				}
			case "L4_DST_PORT":
				if ck.Expect == "443" {
					haveDstPort = true
				}
			}
		}
	}
	if !(havePriority && havePacket && haveProto && haveDstPort) {
		t.Fatalf("missing per-rule config-side checks: PRIORITY=%v PACKET_ACTION=%v IP_PROTOCOL=%v L4_DST_PORT=%v\nchecks=%#v", havePriority, havePacket, haveProto, haveDstPort, np.Checks)
	}
	// Rollback deletes ACL_RULE then ACL_TABLE, in that order and nothing else ACL-related.
	var idxRuleFirst, idxTable int = -1, -1
	var extraACLDeletes []string
	for i, op := range np.Rollback {
		for _, cmd := range op.Redis {
			if strings.Contains(cmd, "del 'ACL_RULE|") {
				if idxRuleFirst < 0 {
					idxRuleFirst = i
				}
			} else if strings.Contains(cmd, "del 'ACL_TABLE|") {
				idxTable = i
			} else if strings.Contains(cmd, "ACL_") {
				extraACLDeletes = append(extraACLDeletes, cmd)
			}
		}
	}
	if idxRuleFirst < 0 || idxTable < 0 {
		t.Fatalf("rollback must delete rules then table: ruleIndex=%d tableIndex=%d", idxRuleFirst, idxTable)
	}
	if !(idxRuleFirst <= idxTable) {
		t.Fatalf("rollback deletes table before rules: ruleIndex=%d tableIndex=%d", idxRuleFirst, idxTable)
	}
	if len(extraACLDeletes) != 0 {
		t.Fatalf("rollback contains unexpected ACL deletions: %v", extraACLDeletes)
	}
}

func TestACLPlan_RendersOnNodesWithAttachments_BindsPerNodePorts(t *testing.T) {
	net := &kubenet.Network{
		ObjectMeta: metav1.ObjectMeta{Name: "svc-acl2", Namespace: "tenant-b"},
		Spec: map[string]any{
			"accessLists": []any{map[string]any{
				"name":  "deny-all-egress",
				"stage": "egress",
				"type":  "l3",
				"rules": []any{map[string]any{"name": "deny", "priority": float64(100), "action": "deny"}},
			}},
			"attachments": []any{
				map[string]any{"node": "leaf01", "attachment": "ethernet1"},
				map[string]any{"node": "leaf02", "attachment": "ethernet2"},
			},
		},
	}
	ports := PortMapper{"ethernet1": "Eth1", "ethernet2": "Eth2"}
	plan, err := ForNetwork(net, Options{Ports: ports})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	// Each node must have a plan and the ACL_TABLE ports@ must contain only its own ports
	for node, np := range plan.Nodes {
		if np == nil {
			t.Fatalf("node %s missing plan", node)
		}
		// Find the ACL_TABLE hset of ports@
		found := false
		for _, op := range np.Ops {
			for _, cmd := range op.Redis {
				if strings.Contains(cmd, "ACL_TABLE|") && strings.Contains(cmd, " ports@ ") {
					// expect the right port for this node
					want := map[string]string{"leaf01": "Eth1", "leaf02": "Eth2"}[node]
					if want == "" {
						t.Fatalf("unexpected node %s in test", node)
					}
					if !strings.Contains(cmd, fmt.Sprintf("'%s'", want)) {
						t.Errorf("node %s ACL_TABLE ports@ does not contain its own port %q: %s", node, want, cmd)
					}
					found = true
				}
			}
		}
		if !found {
			t.Errorf("node %s had no ACL_TABLE ports@ write", node)
		}
	}
}

func TestACLOnlyNetwork_WithNoAttachmentsIsError(t *testing.T) {
	net := &kubenet.Network{
		ObjectMeta: metav1.ObjectMeta{Name: "svc-acl3", Namespace: "tenant-c"},
		Spec: map[string]any{
			"accessLists": []any{map[string]any{
				"name":  "deny-all",
				"stage": "ingress",
				"type":  "l3",
				"rules": []any{map[string]any{"name": "deny", "priority": float64(100), "action": "deny"}},
			}},
			"attachments": []any{},
		},
	}
	_, err := ForNetwork(net, Options{Ports: PortMapper{"ethernet1": "Eth1"}})
	if err == nil {
		t.Fatal("expected error for ACL-only network with no attachments")
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

// TestL3VLANForVNIStaysInBand pins the fold that Vlan4250 broke. The original
// derivation was a straight offset (4000 + vni-10000), so any l3vni above
// 10094 walked out of the 12-bit VLAN space: l3vni 10250 produced "Vlan4250".
// l3OverlayRedis writes VLAN rows through raw redis rather than the GCU, so
// that invalid row reached CONFIG_DB unvalidated and then failed every later
// GCU patch on the node with "Data Loading Failed", blocking services that had
// nothing to do with the offending one.
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
	// The specific value observed on leaf01.
	if got, _ := L3VLANForVNI(10250); got == 4250 {
		t.Fatal("l3vni 10250 still derives the invalid Vlan4250")
	}
}

// TestCollidingL3VNIsAreRefused covers the cost of folding: two l3vnis exactly
// one band apart derive the same L3VLAN, which would put two VRFs on one SVI.
func TestCollidingL3VNIsAreRefused(t *testing.T) {
	net := &kubenet.Network{Spec: map[string]any{
		"routers": []any{
			map[string]any{"name": "vrf-a", "l3vni": float64(10010), "prefixes": []any{"10.0.0.0/24"}},
			map[string]any{"name": "vrf-b", "l3vni": float64(10010 + l3VLANBandSize), "prefixes": []any{"10.1.0.0/24"}},
		},
		"attachments": []any{map[string]any{"node": "leaf01", "attachment": "wan1", "vrf": "vrf-a"}},
	}}
	_, err := ForNetwork(net, Options{Ports: PortMapper{"wan1": "eth4"}})
	if err == nil {
		t.Fatal("ForNetwork accepted two l3vnis that derive the same L3VLAN")
	}
	if !strings.Contains(err.Error(), "derive L3VLAN") {
		t.Errorf("error does not explain the collision: %v", err)
	}
}

// TestVTEPPlanBouncesAStuckTunnelMap covers the vxlanmgrd create-once behaviour:
// re-applying an identical VXLAN_TUNNEL_MAP row logs "Map already present" and
// skips creating the device, so a service that lost its vtep device could never
// recover through a plain reconcile — every pass rewrote the row that was
// already there. The plan must delete and re-add the row when the device is
// still missing after the wait.
func TestVTEPPlanBouncesAStuckTunnelMap(t *testing.T) {
	plan, err := ForNetwork(l2Network(100, 10100), Options{Ports: PortMapper{"ethernet1": "eth3"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	shell := allShell(plan.Nodes["leaf01"])
	key := "VXLAN_TUNNEL_MAP|vtep1|map_10100_Vlan100"
	if !strings.Contains(shell, "del '"+key+"'") {
		t.Errorf("plan never bounces the tunnel-map row when the vtep is missing:\n%s", shell)
	}
	if !strings.Contains(shell, "hset '"+key+"' vni '10100' vlan 'Vlan100'") {
		t.Errorf("plan deletes the tunnel-map row without re-adding it:\n%s", shell)
	}
	// The bounce must be conditional: a healthy device must not be churned.
	if !strings.Contains(shell, "ip link show vtep1-100 >/dev/null 2>&1 || {") {
		t.Errorf("the bounce is unconditional; it must only run when the device is absent:\n%s", shell)
	}
}

// TestPlanAcceptsNodeKind (T188): the renderer accepts the target node kind so
// a plan can differ per kind (sonic-vs container vs sonic-vm guest). An empty
// kind means sonic-vs; an unknown kind is refused rather than guessed.
func TestPlanAcceptsNodeKind(t *testing.T) {
	if _, err := ForNetwork(l2Network(108, 10004), Options{Ports: PortMapper{"ethernet1": "eth3"}, NodeKind: "sonic-vm"}); err != nil {
		t.Fatalf("sonic-vm plan refused: %v", err)
	}
	if _, err := ForNetwork(l2Network(108, 10004), Options{Ports: PortMapper{"ethernet1": "eth3"}, NodeKind: ""}); err != nil {
		t.Fatalf("empty kind (sonic-vs default) refused: %v", err)
	}
	_, err := ForNetwork(l2Network(108, 10004), Options{Ports: PortMapper{"ethernet1": "eth3"}, NodeKind: "junos"})
	if err == nil {
		t.Fatal("unknown node kind accepted; it must be refused")
	}
}

// The p4-acl-trial proof (scripts/spike/networks/acl.yaml) converged on the
// config side but found two sonic-vm deltas in the APPLIED view, plus one
// timing delta:
//  1. vm's orchagent renders the table's bind points as a count-prefixed LIST
//     ("2:SAI_ACL_BIND_POINT_TYPE_PORT,SAI_ACL_BIND_POINT_TYPE_LAG"), so an
//     exact match on "SAI_ACL_BIND_POINT_TYPE_PORT" can never hold;
//  2. qualifier-less rules (the rendered default forward rule) never become
//     SAI_OBJECT_TYPE_ACL_ENTRY objects on vm (sairedis.rec shows creates only
//     for qualifier-carrying rules), so MinCount must not count them;
//  3. ASIC materialization is asynchronous on vm — the trial's verify ran
//     before the table/entry objects existed.
//
// The vs rendering stays byte-identical (exact match, full MinCount, no wait).
func TestACLPlanPerKind_VMAppliedViewToleratesListBindPointsAndSkipsQualifierlessEntries(t *testing.T) {
	aclNet := func() *kubenet.Network {
		return &kubenet.Network{
			ObjectMeta: metav1.ObjectMeta{Name: "p4-trial-acl", Namespace: "agentic-netops-system"},
			Spec: map[string]any{
				"accessLists": []any{map[string]any{
					"name": "p4-trial-acl", "stage": "ingress", "type": "l3", "defaultAction": "forward",
					"rules": []any{map[string]any{
						"name": "rule1", "priority": float64(9990), "action": "forward",
						"protocol": "tcp", "sourcePrefix": "10.0.0.0/8", "destinationPort": "5201",
					}},
				}},
				"attachments": []any{
					map[string]any{"node": "leaf01", "attachment": "eth3"},
					map[string]any{"node": "leaf02", "attachment": "eth3"},
				},
			},
		}
	}
	keysMatch := func(np *NodePlan, key string) *Check {
		for _, c := range np.Checks {
			if c.Type == "redis-keys-match" && strings.Contains(c.RedisKey, key) {
				cc := c
				return &cc
			}
		}
		return nil
	}

	vm, err := ForNetwork(aclNet(), Options{Ports: vmPortMap, NodeKind: "sonic-vm"})
	if err != nil {
		t.Fatalf("sonic-vm ForNetwork: %v", err)
	}
	np := vm.Nodes["leaf01"]
	tableCheck := keysMatch(np, "ACL_TABLE")
	if tableCheck == nil {
		t.Fatal("sonic-vm acl plan lost its applied-table check")
	}
	if got := tableCheck.MatchFields["SAI_ACL_TABLE_ATTR_ACL_BIND_POINT_TYPE_LIST"]; got != "~SAI_ACL_BIND_POINT_TYPE_PORT" {
		t.Fatalf("sonic-vm applied-table bind point must use the contains form (vm renders a count-prefixed list), got %q", got)
	}
	entryCheck := keysMatch(np, "ACL_ENTRY")
	if entryCheck == nil {
		t.Fatal("sonic-vm acl plan lost its applied-entry check")
	}
	if entryCheck.MinCount != 1 {
		t.Fatalf("sonic-vm applied-entry MinCount must count qualifier-carrying rules only (default forward never materializes), got %d", entryCheck.MinCount)
	}
	waitOK := false
	for _, op := range np.Ops {
		for _, sh := range op.Shell {
			if strings.Contains(sh, "ASIC_STATE:SAI_OBJECT_TYPE_ACL_TABLE") && strings.Contains(sh, "sleep") {
				waitOK = true
			}
		}
	}
	if !waitOK {
		t.Fatal("sonic-vm acl plan needs a bounded wait for asynchronous ASIC materialization before the applied checks")
	}

	vs, err := ForNetwork(aclNet(), Options{Ports: PortMapper{"eth3": "eth3"}, NodeKind: "sonic-vs"})
	if err != nil {
		t.Fatalf("sonic-vs ForNetwork: %v", err)
	}
	vsTable := keysMatch(vs.Nodes["leaf01"], "ACL_TABLE")
	if vsTable == nil || vsTable.MatchFields["SAI_ACL_TABLE_ATTR_ACL_BIND_POINT_TYPE_LIST"] != "SAI_ACL_BIND_POINT_TYPE_PORT" {
		t.Fatalf("sonic-vs applied-table rendering changed; vs must keep the exact bind-point match: %+v", vsTable)
	}
	vsEntry := keysMatch(vs.Nodes["leaf01"], "ACL_ENTRY")
	if vsEntry == nil || vsEntry.MinCount != 2 {
		t.Fatalf("sonic-vs applied-entry rendering changed; vs must keep MinCount over every rendered rule: %+v", vsEntry)
	}
	for _, op := range vs.Nodes["leaf01"].Ops {
		for _, sh := range op.Shell {
			if strings.Contains(sh, "ASIC_STATE") {
				t.Fatalf("sonic-vs acl rendering gained a wait op; vs output must stay byte-identical:\n%s", sh)
			}
		}
	}
}

// The p4-macvrf-gw-trial proof converged with ZERO diffs — but on a lab that
// already carried the VTEP baseline the healed mac-vrf trial left behind (the
// IRB plan never ensures it, and plans never roll back manager-owned rows). On
// a fresh sonic-vm lab the L2VNI's map row cannot build vtep1-<vlan> without
// VXLAN_TUNNEL|vtep1 + EVPN_NVO|nvo1. The vm IRB plan must ensure the baseline
// itself; the vs rendering stays byte-identical.
func TestMACVRFGWPlanPerKind_VMGuestNeedsItsVTEPBaseline(t *testing.T) {
	irbNet := func() *kubenet.Network {
		return &kubenet.Network{
			ObjectMeta: metav1.ObjectMeta{Name: "p4-trial-gw", Namespace: "agentic-netops-system"},
			Spec: map[string]any{
				"bridgeDomains": []any{map[string]any{
					"name": "bd-gw1", "vlan": float64(3502), "l2vni": float64(13502),
					"irb":  map[string]any{"vrf": "p4-trial-gw", "gatewayIPv4": "10.199.2.1/24"},
					"evpn": map[string]any{"routeTargets": map[string]any{"export": []any{"65000:13502"}}},
				}},
				"routers": []any{map[string]any{
					"name": "p4-trial-gw", "l3vni": float64(13519), "rd": "65000:19",
					"routeTargets": map[string]any{"import": []any{"65000:19"}, "export": []any{"65000:19"}},
				}},
				"attachments": []any{
					map[string]any{"node": "leaf01", "attachment": "eth3", "vlan": float64(3502)},
					map[string]any{"node": "leaf02", "attachment": "eth3", "vlan": float64(3502)},
				},
			},
		}
	}
	vm, err := ForNetwork(irbNet(), Options{Ports: vmPortMap, NodeKind: "sonic-vm"})
	if err != nil {
		t.Fatalf("sonic-vm ForNetwork: %v", err)
	}
	np := vm.Nodes["leaf01"]
	if np == nil || len(np.Ops) == 0 {
		t.Fatal("leaf01 plan missing")
	}
	first := np.Ops[0]
	if len(first.Shell) != 1 || len(first.GCU) != 0 {
		t.Fatalf("sonic-vm mac-vrf-gw plan must start with the VTEP baseline shell op, got %#v", first)
	}
	for _, needle := range []string{"Loopback0", "VXLAN_TUNNEL|vtep1", "EVPN_NVO|nvo1"} {
		if !strings.Contains(first.Shell[0], needle) {
			t.Fatalf("sonic-vm mac-vrf-gw VTEP baseline op missing %q:\n%s", needle, first.Shell[0])
		}
	}
	if vs, err := ForNetwork(irbNet(), Options{Ports: PortMapper{"eth3": "eth3"}, NodeKind: "sonic-vs"}); err != nil {
		t.Fatalf("sonic-vs ForNetwork: %v", err)
	} else if vsFirst := vs.Nodes["leaf01"].Ops[0]; len(vsFirst.GCU) == 0 || len(vsFirst.Shell) != 0 {
		t.Fatalf("sonic-vs mac-vrf-gw rendering changed; first op must stay the VRF GCU row, got %#v", vsFirst)
	}
}

func TestProbePingCheckCarriesTheFixedContractFields(t *testing.T) {
	// T327 (contracts/fabricplan-srv6.md §2): the one new check type carries
	// probeFrom, probeTo, addr, size and count — and nothing else is needed
	// for the executor to run the one fixed ping argv in the registered
	// client container.
	ck := Check{Type: "probe-ping", ProbeFrom: "leaf01/wan1", ProbeTo: "leaf02/wan1",
		Addr: "192.168.2.10", Size: 8900, Count: 3}
	if ck.ProbeFrom != "leaf01/wan1" || ck.ProbeTo != "leaf02/wan1" {
		t.Fatalf("probe attachments lost: %#v", ck)
	}
	if ck.Size != 8900 || ck.Count != 3 || ck.Addr != "192.168.2.10" {
		t.Fatalf("probe ping parameters lost: %#v", ck)
	}
	b, err := json.Marshal(ck)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, field := range []string{`"probeFrom":"leaf01/wan1"`, `"probeTo":"leaf02/wan1"`,
		`"addr":"192.168.2.10"`, `"size":8900`, `"count":3`, `"type":"probe-ping"`} {
		if !strings.Contains(string(b), field) {
			t.Fatalf("probe-ping JSON missing %s: %s", field, b)
		}
	}
	// The unused vocabulary fields must not leak into the JSON of a
	// probe-ping check (omitempty everywhere else in the struct).
	for _, field := range []string{"redisKey", "iface", "master", "command", "expect"} {
		if strings.Contains(string(b), `"`+field+`":`) {
			t.Fatalf("probe-ping check leaks unused field %q: %s", field, b)
		}
	}
}
