// SPDX-License-Identifier: Apache-2.0
package fabricplan

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/mairp/agentic-netops/api/v1alpha1"
)

// srv6Fixture is the recorded lab shape (vpn-setup.sh): two attachments,
// leaf01/wan1 and leaf02/wan1, locators fcbb:bbbb:3::/48 and fcbb:bbbb:4::/48,
// function space :11::. The spine legs are PER NODE and DIFFER per leaf
// (lab/profiles/sonic-vm/fabric.yaml): leaf01 peers 2001:db8:1::3 toward
// spine01 while leaf02 peers 2001:db8:1::5 — spine02 likewise ::3 vs ::5.
func srv6Fixture() (*v1alpha1.SRv6Service, Allocations, SRv6Options) {
	svc := &v1alpha1.SRv6Service{
		ObjectMeta: metav1.ObjectMeta{Name: "svc1", Namespace: "default"},
		Spec: v1alpha1.SRv6ServiceSpec{
			Tenant:     "acme",
			Construct:  "ip-vrf",
			Signalling: "vpn",
			Attachments: []v1alpha1.Attachment{
				{Node: "leaf01", Port: "wan1", Gateway: []v1alpha1.GatewayPrefix{"192.168.1.1/24"}},
				{Node: "leaf02", Port: "wan1", Gateway: []v1alpha1.GatewayPrefix{"192.168.2.1/24"}},
			},
		},
	}
	alloc := Allocations{
		ServiceID:      1,
		VRF:            "Vrf1",
		ServiceSIDs:    map[string]string{"leaf01": "fcbb:bbbb:3:11::/64", "leaf02": "fcbb:bbbb:4:11::/64"},
		ClientPrefixes: map[string]string{"leaf01": "192.168.1.0/24", "leaf02": "192.168.2.0/24"},
	}
	opts := SRv6Options{
		Ports:    PortMapper{"wan1": "Ethernet12"},
		NodeKind: "sonic-vm",
		SpineLinks: map[string]map[string]string{
			"leaf01": {"spine01": "2001:db8:1::3", "spine02": "2001:db8:2::3"},
			"leaf02": {"spine01": "2001:db8:1::5", "spine02": "2001:db8:2::5"},
		},
		Locators: map[string]string{"leaf01": "fcbb:bbbb:3::/48", "leaf02": "fcbb:bbbb:4::/48"},
	}
	return svc, alloc, opts
}

func mustRender(t *testing.T, svc *v1alpha1.SRv6Service, alloc Allocations, opts SRv6Options) *Plan {
	t.Helper()
	p, err := ForSRv6Service(svc, alloc, opts)
	if err != nil {
		t.Fatalf("ForSRv6Service: %v", err)
	}
	return p
}

// T305: refusal by name, and every missing allocation is an error, never a
// default.
func TestSRv6RefusesUnprovenVariantsAndMissingAllocations(t *testing.T) {
	svc, alloc, opts := srv6Fixture()

	cases := []struct {
		name    string
		mutate  func(*v1alpha1.SRv6Service)
		wantErr string
	}{
		{"mac-vrf any signalling", func(s *v1alpha1.SRv6Service) {
			s.Spec.Construct, s.Spec.Signalling = "mac-vrf", "evpn"
			v := int64(100)
			s.Spec.VLAN = &v
		}, "mac-vrf/evpn"},
		{"ip-vrf evpn", func(s *v1alpha1.SRv6Service) {
			s.Spec.Signalling = "evpn"
		}, "ip-vrf/evpn"},
		{"unknown construct", func(s *v1alpha1.SRv6Service) {
			s.Spec.Construct = "bridge"
		}, "unknown SRv6 variant"},
	}
	for _, tc := range cases {
		s2 := *svc
		s2.Spec = svc.Spec
		tc.mutate(&s2)
		_, err := ForSRv6Service(&s2, alloc, opts)
		if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
			t.Fatalf("%s: want error containing %q, got %v", tc.name, tc.wantErr, err)
		}
		if !strings.Contains(err.Error(), "supported: ip-vrf/vpn, steering") {
			t.Fatalf("%s: refusal must name the supported set, got %v", tc.name, err)
		}
	}

	// ip-vrf/evpn and mac-vrf/evpn render NOTHING (T313-T318, T319-T324):
	// both are refused by name with zero node plans.
	for _, tc := range []struct{ construct, signalling, want string }{
		{"ip-vrf", "evpn", "ip-vrf/evpn"},
		{"mac-vrf", "evpn", "mac-vrf/evpn"},
		{"mac-vrf", "", "mac-vrf/evpn"},
	} {
		s2 := *svc
		s2.Spec = svc.Spec
		s2.Spec.Construct, s2.Spec.Signalling = tc.construct, tc.signalling
		p, err := ForSRv6Service(&s2, alloc, opts)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Fatalf("%s/%s: want error containing %q, got %v", tc.construct, tc.signalling, tc.want, err)
		}
		if p != nil && len(p.Nodes) != 0 {
			t.Fatalf("%s/%s rendered %d node plans", tc.construct, tc.signalling, len(p.Nodes))
		}
	}

	// missing / inconsistent allocations and options, each an error
	bad := []struct {
		name   string
		mutate func(*Allocations, SRv6Options)
	}{
		{"service id 0", func(a *Allocations, o SRv6Options) { a.ServiceID = 0 }},
		{"vrf mismatch", func(a *Allocations, o SRv6Options) { a.VRF = "Vrf9" }},
		{"missing service SID", func(a *Allocations, o SRv6Options) { delete(a.ServiceSIDs, "leaf02") }},
		{"missing client prefix", func(a *Allocations, o SRv6Options) { delete(a.ClientPrefixes, "leaf01") }},
		{"bad client prefix", func(a *Allocations, o SRv6Options) { a.ClientPrefixes["leaf01"] = "192.168.1.0/23" }},
		{"missing spine links", func(a *Allocations, o SRv6Options) { o.SpineLinks = map[string]map[string]string{} }},
		{"node missing from spine links", func(a *Allocations, o SRv6Options) { delete(o.SpineLinks, "leaf02") }},
		{"empty spine legs on a node", func(a *Allocations, o SRv6Options) { o.SpineLinks["leaf02"] = map[string]string{"spine01": "", "spine02": ""} }},
		{"missing locator", func(a *Allocations, o SRv6Options) { delete(o.Locators, "leaf02") }},
		{"unknown port", func(a *Allocations, o SRv6Options) { o.Ports = PortMapper{"eth9": "Ethernet9"} }},
		{"unknown node kind", func(a *Allocations, o SRv6Options) { o.NodeKind = "cumulus" }},
	}
	for _, tc := range bad {
		a, o := alloc, opts
		tc.mutate(&a, o)
		if _, err := ForSRv6Service(svc, a, o); err == nil {
			t.Fatalf("%s: expected an error", tc.name)
		}
	}
}

// T307-T312: the ip-vrf/vpn happy path — per-leaf ops exactly per §3.1, no
// locator write anywhere, checks and rollback per §3.1/§2b.
func TestSRv6IPVRFVPNHappyPath(t *testing.T) {
	svc, alloc, opts := srv6Fixture()
	p := mustRender(t, svc, alloc, opts)

	// one NodePlan per attachment node, no spine nodes ever
	if len(p.Nodes) != 2 {
		t.Fatalf("want 2 node plans, got %d", len(p.Nodes))
	}
	if _, ok := p.Nodes["spine01"]; ok {
		t.Fatal("a spine must never get a NodePlan (contract §1)")
	}

	for _, n := range []string{"leaf01", "leaf02"} {
		np := p.Nodes[n]
		if np.Node != n {
			t.Fatalf("node plan name mismatch: %q", np.Node)
		}
		var gcu, shell []string
		for _, op := range np.Ops {
			set := 0
			for _, l := range []int{len(op.GCU), len(op.Redis), len(op.Shell), len(op.VTYSh), len(op.FRRConf)} {
				if l > 0 {
					set++
				}
			}
			if set != 1 {
				t.Fatalf("%s: op mixes classes: %#v", n, op)
			}
			for _, g := range op.GCU {
				b, _ := json.Marshal(g)
				gcu = append(gcu, string(b))
			}
			shell = append(shell, op.Shell...)
		}
		gcuAll := strings.Join(gcu, "\n")
		shellAll := strings.Join(shell, "\n")

		// GCU: per-key VRF add + field-level INTERFACE adds (never a
		// whole-table /INTERFACE add; fabric rows must survive)
		if !strings.Contains(gcuAll, "/VRF/Vrf1") {
			t.Fatalf("%s: no /VRF/Vrf1 add:\n%s", n, gcuAll)
		}
		if strings.Contains(gcuAll, `"path":"/VRF"`) || strings.Contains(gcuAll, `"path":"/INTERFACE"`) {
			t.Fatalf("%s: whole-table add present:\n%s", n, gcuAll)
		}
		if !strings.Contains(gcuAll, "/INTERFACE/Ethernet12") || !strings.Contains(gcuAll, "vrf_name") {
			t.Fatalf("%s: no field-level attachment adds:\n%s", n, gcuAll)
		}
		wantGW := "192.168.1.1/24"
		if n == "leaf02" {
			wantGW = "192.168.2.1/24"
		}
		if !strings.Contains(gcuAll, strings.ReplaceAll(wantGW, "/", "~1")) {
			t.Fatalf("%s: access prefix not ~1-escaped onto /INTERFACE:\n%s", n, gcuAll)
		}

		// Shell: decap (device-read vrftable), steering toward the PEER SID,
		// the /48 pin at metric 5.
		peerSID := "fcbb:bbbb:4:11::"
		peer24 := "192.168.2.0/24"
		ownSID := "fcbb:bbbb:3:11::"
		wantLeg := "2001:db8:1::3"  // leaf01's OWN spine01 leg (fabric.yaml)
		wrongLeg := "2001:db8:1::5" // leaf02's leg — must never appear on leaf01
		if n == "leaf02" {
			peerSID, peer24 = "fcbb:bbbb:3:11::", "192.168.1.0/24"
			ownSID = "fcbb:bbbb:4:11::"
			wantLeg, wrongLeg = "2001:db8:1::5", "2001:db8:1::3"
		}
		for _, want := range []string{
			"ip -6 route replace fcbb:bbbb:",
			"encap seg6local action End.DT46 vrftable $(ip -d link show Vrf1 2>/dev/null | grep -o 'table [0-9]*' | cut -d' ' -f2) dev Vrf1",
			"ip route replace " + peer24 + " vrf Vrf1 encap seg6 mode encap segs " + peerSID + " dev Ethernet0",
		} {
			if !strings.Contains(shellAll, want) {
				t.Fatalf("%s: missing shell command %q in:\n%s", n, want, shellAll)
			}
		}
		// the /48 pin targets the PEER locator, via THIS leaf's own spine01
		// leg address (the legs differ per leaf: ::3 on leaf01, ::5 on
		// leaf02 — a flat spine->address map rendered leaf01's leg onto
		// leaf02 and the live pin failed with "No route to host").
		peer48 := "fcbb:bbbb:4::/48"
		if n == "leaf02" {
			peer48 = "fcbb:bbbb:3::/48"
		}
		if !strings.Contains(shellAll, peer48+" via "+wantLeg+" dev Ethernet0 metric 5") {
			t.Fatalf("%s: /48 pin must target the PEER locator %s via %s (the leaf's OWN spine01 leg):\n%s", n, peer48, wantLeg, shellAll)
		}
		if strings.Contains(shellAll, "via "+wrongLeg+" ") {
			t.Fatalf("%s: pin used another leaf's spine leg %s:\n%s", n, wrongLeg, shellAll)
		}

		// T325: no op touches the locator tables, and no control-plane write
		// class exists at all in an SRv6 service plan.
		if strings.Contains(gcuAll, "SRV6_MY_LOCATORS") || strings.Contains(gcuAll, "SRV6_MY_SIDS") ||
			strings.Contains(gcuAll, "locator") || strings.Contains(gcuAll, "segment-routing") {
			t.Fatalf("%s: GCU op touches locator/SID state:\n%s", n, gcuAll)
		}
		for _, op := range np.Ops {
			if len(op.VTYSh) != 0 || len(op.FRRConf) != 0 || len(op.Redis) != 0 {
				t.Fatalf("%s: SRv6 plan emitted a VTYSh/FRRConf/Redis op: %#v", n, op)
			}
		}

		// checks per §3.1's Check column
		var types []string
		for _, ck := range np.Checks {
			types = append(types, ck.Type)
		}
		typesAll := strings.Join(types, ",")
		for _, want := range []string{"redis-exists", "ip-addr", "ip-master", "command"} {
			if !strings.Contains(typesAll, want) {
				t.Fatalf("%s: checks missing %s: %s", n, want, typesAll)
			}
		}
		for _, ck := range np.Checks {
			if ck.Type == "redis-exists" && ck.RedisKey != "VRF|Vrf1" {
				t.Fatalf("%s: VRF check key %q", n, ck.RedisKey)
			}
			if ck.Type == "ip-addr" && ck.OnClient == "" && (ck.Iface != "Ethernet12" || ck.Addr != wantGW) {
				t.Fatalf("%s: ip-addr check %#v", n, ck)
			}
			if ck.Type == "ip-master" && ck.Master != "Vrf1" {
				t.Fatalf("%s: ip-master check %#v", n, ck)
			}
			// receipt-literal read-backs: the executor's command check is a
			// raw strings.Contains against the LIVE output, so each Expect
			// must be a contiguous substring of the kernel's print format
			// (spike-vpn-readback-leaf01/leaf02, spike-steering-path):
			//   decap     "fcbb:bbbb:3:11::/64  encap seg6local action End.DT46 ..."
			//             (TWO spaces after the prefix),
			//   steering  "... encap seg6 mode encap segs 1 [ fcbb:bbbb:4:11:: ] dev ..."
			//             (count and brackets),
			//   /48 pin   "fcbb:bbbb:3::/48 via 2001:db8:1::5 dev ..." (single spaces).
			if ck.Type == "command" && strings.Contains(ck.Command, "grep seg6local") &&
				ck.Expect != ownSID+"/64  encap seg6local action End.DT46" {
				t.Fatalf("%s: decap read-back Expect must be the receipt-literal line: %#v", n, ck)
			}
			if ck.Type == "command" && strings.Contains(ck.Command, "| grep encap") &&
				ck.Expect != "encap seg6 mode encap segs 1 [ "+peerSID+" ]" {
				t.Fatalf("%s: steering read-back Expect must be the receipt-literal segs list: %#v", n, ck)
			}
			if ck.Type == "command" && strings.Contains(ck.Command, "grep 'metric 5'") &&
				ck.Expect != peer48+" via "+wantLeg {
				t.Fatalf("%s: /48 pin read-back must name the peer locator via the node's own leg: %#v", n, ck)
			}
			if ck.Type == "command" && !strings.Contains(ck.Command, "show") {
				t.Fatalf("%s: command check must be read-only: %#v", n, ck)
			}
		}

		// rollback per §2b: routes first, then /INTERFACE rows (service-owned
		// only), then /VRF (own op), then the node port flush and the client
		// eth1 flush.
		if len(np.Rollback) != 5 {
			t.Fatalf("%s: want 5 rollback ops (routes, INTERFACE, VRF, node flush, client flush), got %d", n, len(np.Rollback))
		}
		rbShell := strings.Join(np.Rollback[0].Shell, "\n")
		if !strings.Contains(rbShell, "ip route del vrf Vrf1") {
			t.Fatalf("%s: rollback must del the vrf steering route first:\n%s", n, rbShell)
		}
		if !strings.Contains(rbShell, "for i in 1 2 3 4 5; do ip -6 route del fcbb:bbbb:") {
			t.Fatalf("%s: rollback must loop-del the decap /64 (vpn-rollback.sh):\n%s", n, rbShell)
		}
		for i, op := range np.Rollback[1:3] {
			if len(op.GCU) == 0 {
				t.Fatalf("%s: rollback op %d must be a GCU remove", n, i+1)
			}
			for _, g := range op.GCU {
				if g["op"] != "remove" {
					t.Fatalf("%s: rollback GCU op must remove, got %v", n, g["op"])
				}
			}
		}
		paths := []string{np.Rollback[1].GCU[0]["path"].(string), np.Rollback[1].GCU[1]["path"].(string), np.Rollback[2].GCU[0]["path"].(string)}
		if !strings.Contains(paths[0], "/INTERFACE/Ethernet12|") || paths[1] != "/INTERFACE/Ethernet12" || paths[2] != "/VRF" {
			t.Fatalf("%s: rollback GCU order must be /INTERFACE rows then /VRF: %v", n, paths)
		}
		if np.Rollback[3].Shell[0] != "ip addr flush dev Ethernet12" {
			t.Fatalf("%s: rollback must flush the attachment port: %v", n, np.Rollback[3].Shell)
		}
		// client-addressing rollback (§3.1: flush the port), inside the probe
		// client container — eth1 only.
		if np.Rollback[4].OnClient != n+"/wan1" || strings.Join(np.Rollback[4].Shell, "|") != "ip addr flush dev eth1" {
			t.Fatalf("%s: client rollback must flush eth1 via OnClient, got %#v", n, np.Rollback[4])
		}

		// client-addressing op/check per §3.1 (vpn-setup.sh client block):
		// flush eth1, the claimed /24 at host .2, default route via the
		// gateway host — routed into the probe client container via OnClient.
		wantClientAddr := "192.168.1.2/24"
		wantGWHost := "192.168.1.1"
		if n == "leaf02" {
			wantClientAddr, wantGWHost = "192.168.2.2/24", "192.168.2.1"
		}
		var clientOps []*Op
		for i := range np.Ops {
			if np.Ops[i].OnClient != "" {
				clientOps = append(clientOps, &np.Ops[i])
			}
		}
		if len(clientOps) != 1 {
			t.Fatalf("%s: want exactly one OnClient op, got %d", n, len(clientOps))
		}
		wantShell := []string{
			"ip addr flush dev eth1",
			"ip addr add " + wantClientAddr + " dev eth1",
			"ip route replace default via " + wantGWHost + " dev eth1",
		}
		if strings.Join(clientOps[0].Shell, "\n") != strings.Join(wantShell, "\n") {
			t.Fatalf("%s: client op commands %v, want %v", n, clientOps[0].Shell, wantShell)
		}
		if clientOps[0].OnClient != n+"/wan1" {
			t.Fatalf("%s: client op OnClient %q, want %q", n, clientOps[0].OnClient, n+"/wan1")
		}
		foundClientCheck := false
		for _, ck := range np.Checks {
			if ck.OnClient != "" {
				if ck.Type != "ip-addr" || ck.Iface != "eth1" || ck.Addr != wantClientAddr || ck.OnClient != n+"/wan1" {
					t.Fatalf("%s: client check wrong: %#v", n, ck)
				}
				foundClientCheck = true
			}
		}
		if !foundClientCheck {
			t.Fatalf("%s: no OnClient client-addressing check", n)
		}
		// eth0 is the client container's mgmt veth: NO op may ever touch it.
		for _, op := range np.Ops {
			for _, s := range op.Shell {
				if strings.Contains(s, "eth0") {
					t.Fatalf("%s: op touches eth0: %q", n, s)
				}
			}
		}
	}
}

// T305 coverage companion: item counts per leaf align (6 ops, 8 checks, 5
// rollback ops for the unsteered happy path; +1 op/check when steered on the
// ingress leaf). See the item table in srv6.go's package comment.
func TestSRv6ItemCountsAlign(t *testing.T) {
	svc, alloc, opts := srv6Fixture()
	p := mustRender(t, svc, alloc, opts)
	for _, n := range []string{"leaf01", "leaf02"} {
		np := p.Nodes[n]
		if len(np.Ops) != 6 || len(np.Checks) != 8 || len(np.Rollback) != 5 {
			t.Fatalf("%s: unsteered counts ops=%d checks=%d rollback=%d, want 6/8/5",
				n, len(np.Ops), len(np.Checks), len(np.Rollback))
		}
	}
}

// steering: preferred pin on the INGRESS leaf only, via the preferred spine's
// link address; the alternate spine never appears in ops.
func TestSRv6SteeringIngressOnly(t *testing.T) {
	svc, alloc, opts := srv6Fixture()
	svc.Spec.Path = v1alpha1.PathSelection{PreferredSpine: "spine01", AlternateSpine: "spine02"}
	p := mustRender(t, svc, alloc, opts)

	if len(p.Nodes) != 2 {
		t.Fatalf("steered service must still have exactly the 2 attachment leaves, got %d", len(p.Nodes))
	}
	if _, ok := p.Nodes["spine01"]; ok {
		t.Fatal("spine got a NodePlan")
	}
	ingress, standby := p.Nodes["leaf01"], p.Nodes["leaf02"]
	if len(ingress.Ops) != 7 || len(standby.Ops) != 6 {
		t.Fatalf("steered counts: ingress ops=%d standby ops=%d, want 7/6", len(ingress.Ops), len(standby.Ops))
	}
	var pin string
	for _, op := range ingress.Ops {
		for _, s := range op.Shell {
			if strings.Contains(s, "metric 20") {
				pin = s
			}
		}
	}
	if pin != "ip -6 route replace fcbb:bbbb:4:11:: from :: via 2001:db8:1::3 dev Ethernet0 metric 20" {
		t.Fatalf("preferred pin wrong: %q", pin)
	}
	for _, n := range []string{"leaf01", "leaf02"} {
		for _, op := range p.Nodes[n].Ops {
			for _, s := range op.Shell {
				if strings.Contains(s, "2001:db8:2::") {
					t.Fatalf("%s: alternate spine address leaked into ops: %q", n, s)
				}
			}
		}
	}
	found := false
	for _, ck := range ingress.Checks {
		if ck.Type == "command" && strings.Contains(ck.Expect, "from :: via 2001:db8:1::3") {
			found = true
		}
	}
	if !found {
		t.Fatal("ingress leaf missing the preferred-pin check")
	}
	if len(ingress.Checks) != 9 {
		t.Fatalf("ingress checks=%d, want 9", len(ingress.Checks))
	}
	// the preferred spine's leg must exist on the INGRESS node's OWN map: a
	// node without that leg is refused by name, never rendered via another
	// leaf's address.
	o2 := opts
	o2.SpineLinks["leaf01"] = map[string]string{"spine02": "2001:db8:2::3"}
	if _, err := ForSRv6Service(svc, alloc, o2); err == nil || !strings.Contains(err.Error(), "spine01") {
		t.Fatalf("steered render must refuse a missing preferred-spine leg on the ingress node, got %v", err)
	}
	// rollback dels the pin first
	if !strings.Contains(ingress.Rollback[0].Shell[0], "ip -6 route del fcbb:bbbb:4:11::") {
		t.Fatalf("steered rollback must del the pin first: %v", ingress.Rollback[0].Shell)
	}
	if len(ingress.Rollback) != 5 {
		t.Fatalf("ingress rollback ops=%d, want 5", len(ingress.Rollback))
	}
}

// T326: byte-identical JSON across two renders, happy path and steered path.
func TestSRv6DeterministicJSON(t *testing.T) {
	svc, alloc, opts := srv6Fixture()
	render := func() []byte {
		p := mustRender(t, svc, alloc, opts)
		b, err := json.Marshal(p)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		return b
	}
	if !bytes.Equal(render(), render()) {
		t.Fatal("happy path renders different bytes across runs")
	}
	svc.Spec.Path = v1alpha1.PathSelection{PreferredSpine: "spine01", AlternateSpine: "spine02"}
	if !bytes.Equal(render(), render()) {
		t.Fatal("steered path renders different bytes across runs")
	}
}
