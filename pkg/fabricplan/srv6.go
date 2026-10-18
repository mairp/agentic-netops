// SPDX-License-Identifier: Apache-2.0
//
// SRv6Service plan rendering (feature 004): the ONLY proven variant,
// ip-vrf/vpn (contracts/fabricplan-srv6.md §3.1), plus the proven steering
// pin (§3.2, ingress leaf only). Every command below is copied from the
// recorded spike builders — scripts/spike/vrf-apply.sh, vpn-setup.sh,
// vpn-rollback.sh, steering-lib.sh — with allocation placeholders; the
// renderer generates nothing (a missing allocation is an error, never a
// default).
//
// The locator is bootstrap-owned (recipe §1a, FR-006): no op here creates,
// changes or removes SRV6_MY_LOCATORS or SRV6_MY_SIDS state, and no VTYSh or
// FRRConf op exists at all. The locators carried in SRv6Options are read only
// to refuse rendering when an attachment node has none.
//
// Item naming convention used by srv6_test.go (per leaf):
//
//	vrf-row            GCU /VRF/<vrf> add          -> redis-exists VRF|<vrf> -> GCU remove /VRF
//	attachment         GCU INTERFACE field adds    -> ip-addr + ip-master    -> GCU row removes
//	kernel-vrf-device  (image-derived, no op)      -> command `ip -br link`  -> (device lingers)
//	decap              Shell End.DT46 route        -> command route show     -> Shell loop-del
//	steering-route     Shell vrf encap seg6 route  -> command vrf route show -> Shell route del
//	locator-pin        Shell /48 via metric 5      -> command metric-5 grep  -> Shell route del
//	preferred-pin      Shell /64 from :: metric 20 -> command route show     -> Shell loop-del
//	                   (steering, ingress leaf only)
//	client-addressing  Shell on the PROBE CLIENT container (Op.OnClient =
//	                   "<node>/<logical-port>"): flush eth1 (NEVER eth0, the
//	                   mgmt interface), the client /24 at host .2, default
//	                   route via the attachment gateway — vpn-setup.sh
//	                   client-addressing block. The executor routes OnClient
//	                   ops/checks into the probe client container via docker
//	                   exec sh -c (executor-transport §4). The ping itself
//	                   stays the datapath check at first activation (the
//	                   probe-ping Check, T328/T329), not a node op.
package fabricplan

import (
	"fmt"
	"net/netip"
	"sort"
	"strings"

	"github.com/mairp/agentic-netops/api/v1alpha1"
)

// SRv6Options carries the site-level state an SRv6Service plan needs. The
// locator per node is bootstrap-owned; it is carried ONLY so the renderer can
// refuse to emit a plan for a node the bootstrap has not locatored yet.
type SRv6Options struct {
	// Ports resolves the spec's logical attachment names to kernel ports
	// (e.g. wan1 -> Ethernet12), exactly as Options.Ports does for Networks.
	Ports PortMapper
	// NodeKind names the SONiC node kind ("sonic-vm" or "sonic-vs"; empty
	// means sonic-vs, as in Options). Anything else is refused.
	NodeKind string
	// SpineLinks maps an attachment NODE to that node's spine legs: spine
	// name -> the IPv6 link address of the leg ON THAT NODE. The legs differ
	// per leaf (lab/profiles/sonic-vm/fabric.yaml: leaf01 peers
	// 2001:db8:1::3 toward spine01 while leaf02 peers 2001:db8:1::5; spine02
	// likewise ::3 vs ::5). A single flat spine->address map rendered
	// leaf01's leg onto leaf02 and the live pin failed with RTNETLINK
	// "No route to host" (measured 2026-10-16), hence the per-node shape.
	// The /48 fabric pin and the preferred pin both use THIS node's leg
	// address toward the pin spine via the leaf uplink Ethernet0
	// (vpn-setup.sh pin_peer_48, spike-steering-path). Without steering the
	// sorted-first spine with a non-empty address on THIS node is used for
	// the /48 pin; with steering the preferred spine is used for both pins.
	// A node missing from the map, or a pin spine without an address on the
	// node, is an error.
	SpineLinks map[string]map[string]string
	// Locators maps node name to the bootstrap-owned locator /48 (e.g.
	// fcbb:bbbb:3::/48). Read-only for the renderer: it never writes one, it
	// only requires the PEER locator for the /48 fabric pin and refuses a
	// plan whose attachment node has none.
	Locators map[string]string
}

// Allocations carries every identifier the controller claimed for one
// SRv6Service (data-model §8.1-§8.6). The renderer generates none of them.
type Allocations struct {
	// ServiceID is the claimed generic identifier (>0); the VRF is
	// Vrf<ServiceID>.
	ServiceID int64
	// VRF is the carried device VRF name. It must be empty or exactly
	// Vrf<ServiceID>; anything else is a caller bug, not a render target.
	VRF string
	// ServiceSIDs maps attachment node to that node's service SID /64 in the
	// function space of the node locator (e.g. fcbb:bbbb:3:11::/64).
	ServiceSIDs map[string]string
	// ClientPrefixes maps attachment node to the claimed client /24 (e.g.
	// 192.168.1.0/24). The attachment gateway address is this prefix with
	// host octet .1, as recorded in vrf-apply.sh.
	ClientPrefixes map[string]string
}

// srv6Uplink is the leaf uplink every recorded pin uses (vpn-setup.sh
// pin_peer_48 and steering-lib.sh/§5a both write `dev Ethernet0`).
const srv6Uplink = "Ethernet0"

// ForSRv6Service renders one SRv6Service into per-node Ops/Checks/Rollback.
// Pure and deterministic: map iteration is always through sorted keys, so
// identical input renders byte-identical JSON.
func ForSRv6Service(svc *v1alpha1.SRv6Service, alloc Allocations, opts SRv6Options) (*Plan, error) {
	// Variant gate (contract §3.3/§4): refuse unproven variants BY NAME.
	variant := svc.Spec.Construct + "/" + svc.Spec.Signalling
	if variant == "mac-vrf/" {
		variant = "mac-vrf/evpn" // controller default signalling for mac-vrf
	}
	switch variant {
	case "ip-vrf/vpn":
		// the only proven per-leaf recipe (recipe §2)
	case "ip-vrf/evpn", "mac-vrf/evpn":
		return nil, errf("variant %s has no proven recipe on this site (supported: ip-vrf/vpn, steering)", variant)
	default:
		return nil, errf("unknown SRv6 variant %q (supported: ip-vrf/vpn, steering)", variant)
	}

	switch opts.NodeKind {
	case "", "sonic-vm", "sonic-vs":
	default:
		return nil, errf("unknown node kind %q (want sonic-vm or sonic-vs)", opts.NodeKind)
	}
	if len(opts.Ports) == 0 {
		return nil, errf("site port map is empty")
	}

	if len(svc.Spec.Attachments) != 2 {
		return nil, errf("exactly two attachments are required, got %d", len(svc.Spec.Attachments))
	}
	a0, a1 := svc.Spec.Attachments[0], svc.Spec.Attachments[1]
	if a0.Node == "" || a1.Node == "" {
		return nil, errf("attachment with empty node")
	}
	if a0.Node == a1.Node {
		return nil, errf("attachments must be on distinct nodes (both %q)", a0.Node)
	}
	nodes := []string{a0.Node, a1.Node}
	sort.Strings(nodes) // deterministic NodePlan order

	if alloc.ServiceID <= 0 {
		return nil, errf("service id must be > 0")
	}
	wantVRF := fmt.Sprintf("Vrf%d", alloc.ServiceID)
	if alloc.VRF != "" && alloc.VRF != wantVRF {
		return nil, errf("allocated VRF %q does not match Vrf<service-id> shape (%s)", alloc.VRF, wantVRF)
	}
	vrf := wantVRF

	type attach struct {
		port   string // kernel port
		logic  string // spec logical port
		sid    string // own service SID /64
		sidFn  string // own service SID without the /64 suffix
		client string // own client /24
		gw     string // client /24 with host octet .1
		loc    string // own bootstrap locator /48
	}
	at := map[string]attach{}
	for _, n := range nodes {
		sid, ok := alloc.ServiceSIDs[n]
		if !ok || sid == "" {
			return nil, errf("no service SID allocated for attachment node %s", n)
		}
		if !strings.HasSuffix(sid, "/64") {
			return nil, errf("service SID %q for %s is not a /64", sid, n)
		}
		client, ok := alloc.ClientPrefixes[n]
		if !ok || client == "" {
			return nil, errf("no client prefix allocated for attachment node %s", n)
		}
		gw, err := gatewayAddr(client)
		if err != nil {
			return nil, errf("client prefix %q for %s: %v", client, n, err)
		}
		loc, ok := opts.Locators[n]
		if !ok || loc == "" {
			// FR-006: the locator is bootstrap-owned; a service on a node
			// without one is refused, never rendered half-way.
			return nil, errf("no bootstrap locator carried for attachment node %s", n)
		}
		att := svc.Spec.Attachments[0]
		if svc.Spec.Attachments[0].Node != n {
			att = svc.Spec.Attachments[1]
		}
		port, err := opts.Ports.Port(att.Port)
		if err != nil {
			return nil, err
		}
		at[n] = attach{
			port: port, logic: att.Port,
			sid: sid, sidFn: strings.TrimSuffix(sid, "/64"),
			client: client, gw: gw, loc: loc,
		}
	}

	// Steering flag for the §3.2 preferred pin (ingress leaf only).
	steered := svc.Spec.Path.PreferredSpine != ""

	plan := &Plan{Nodes: map[string]*NodePlan{}}
	for _, n := range nodes {
		self, peerNode := at[n], other(nodes, n)
		peer := at[peerNode]
		peerLoc, ok := opts.Locators[peerNode]
		if !ok || peerLoc == "" {
			return nil, errf("no bootstrap locator carried for attachment node %s", peerNode)
		}

		// Spine choice for the /48 fabric pin, PER NODE: the preferred spine
		// when the service is steered, else the sorted-first spine carrying
		// a non-empty leg address on THIS node. The pin's via address is
		// always THIS node's own leg (see SpineLinks above).
		legs := opts.SpineLinks[n]
		if len(legs) == 0 {
			return nil, errf("no spine link addresses carried for node %s (opts.SpineLinks)", n)
		}
		pinSpine := ""
		if steered {
			pinSpine = svc.Spec.Path.PreferredSpine
		} else {
			links := make([]string, 0, len(legs))
			for s, v := range legs {
				if v != "" {
					links = append(links, s)
				}
			}
			if len(links) == 0 {
				return nil, errf("no spine link address carried for node %s (opts.SpineLinks)", n)
			}
			sort.Strings(links)
			pinSpine = links[0]
		}
		pinLink, ok := legs[pinSpine]
		if !ok || pinLink == "" {
			return nil, errf("no spine link address carried for spine %s on node %s", pinSpine, n)
		}

		np := &NodePlan{Node: n}

		// vrf-row (contract §3.1): per-key add; the executor promotes it to a
		// whole-table /VRF add when the table is absent, exactly like the
		// bootstrap.
		np.Ops = append(np.Ops, Op{GCU: []map[string]any{
			{"op": "add", "path": "/VRF/" + vrf, "value": map[string]any{}},
		}})

		// attachment (contract §3.1): FIELD-LEVEL adds onto the existing
		// /INTERFACE table — a whole-table add REPLACES it and wipes the
		// fabric link rows (measured, vrf-apply.sh header). The address key
		// carries "/" JSON-pointer-escaped as ~1, else GCU cannot address the
		// row.
		gwKey := "/INTERFACE/" + self.port + "|" + strings.ReplaceAll(self.gw, "/", "~1")
		np.Ops = append(np.Ops, Op{GCU: []map[string]any{
			{"op": "add", "path": "/INTERFACE/" + self.port, "value": map[string]any{"vrf_name": vrf}},
			{"op": "add", "path": gwKey, "value": map[string]any{}},
		}})

		// decap (recipe §2a step 3): the VRF table id is device-allocated, so
		// the recorded read-back (`ip -d link show <vrf> | grep -o 'table
		// [0-9]*'`) is embedded in the command itself — the op reads it on
		// the node, never assumes 1001. The `count` keyword (seg6local
		// option; iproute2 SEG6LOCAL grammar `action ACTION [ OPTIONS ]
		// [ count ]`) turns on the kernel's per-behavior counters for THIS
		// SID's route: `ip -s -6 route show` then reports
		// `packets N bytes M errors 0` inline on the route line — the per-SID
		// forwarding counter spec.md FR-036/Principle IV makes observable,
		// which cmd/fabric-executor/metrics.go scrapes as
		// fabric_executor_srv6_sid_packets_total. Measured live on the
		// sonic-vm guest (kernel 6.1.0-29-2-amd64, iproute2 6.1.0): without
		// `count` the dump carries no counter fields (spike-counters §4 read
		// exactly that) and the spike wrongly concluded per-SID counters do
		// not exist; with it, 4 client pings decapsulated by
		// fcbb:bbbb:3:11::/64 raised that route's own packets counter 0 → 4
		// on both leaves at 0% loss. `count` must sit INSIDE the encap clause
		// (before `dev`); at end-of-line iproute2 rejects it with
		// `Error: either "to" is duplicate, or "count" is a garbage`. The
		// seg6 mode-encap steering route has no count option (only seg6local
		// behaviors count), so the decap counter is the per-SID series this
		// feature exports.
		np.Ops = append(np.Ops, Op{Shell: []string{
			fmt.Sprintf("ip -6 route replace %s encap seg6local action End.DT46 vrftable $(ip -d link show %s 2>/dev/null | grep -o 'table [0-9]*' | cut -d' ' -f2) count dev %s", self.sid, vrf, vrf),
		}})

		// steering-route (recipe §2a step 4): the client /24 of the PEER
		// attachment inside the VRF, encapsulated toward the peer service
		// SID. Command shape copied verbatim from vpn-setup.sh (kernel seg6
		// mode encap; the /48 fabric pin below is REQUIRED so zebra keeps a
		// consistent nhg).
		np.Ops = append(np.Ops, Op{Shell: []string{
			fmt.Sprintf("ip route replace %s vrf %s encap seg6 mode encap segs %s dev %s", peer.client, vrf, peer.sidFn, srv6Uplink),
		}})

		// locator-pin (contract §3.1, REQUIRED for the encap nhg): the PEER
		// locator /48 pinned at metric 5 via the spine leg's link address, so
		// the outer packet's fresh lookup cannot self-loop through the wrong
		// spine (measured, vpn-setup.sh pin_peer_48).
		np.Ops = append(np.Ops, Op{Shell: []string{
			fmt.Sprintf("ip -6 route replace %s via %s dev %s metric 5", peerLoc, pinLink, srv6Uplink),
		}})

		// preferred-pin (contract §3.2, INGRESS LEAF ONLY): the explicit
		// per-service pin through the preferred spine at metric 20. The
		// ingress leaf is the attachment whose node name sorts first — the
		// deterministic generalization of the recorded proof, where leaf01
		// (the first leaf) carried the pin toward leaf02's function space
		// (spike-steering-path, recipe §5a). The alternate spine never
		// appears in a rendered op: switching to it is a failure ACTION
		// (recipe §5), not steady-state config.
		if steered && n == nodes[0] {
			np.Ops = append(np.Ops, Op{Shell: []string{
				fmt.Sprintf("ip -6 route replace %s from :: via %s dev %s metric 20", peer.sidFn, pinLink, srv6Uplink),
			}})
		}

		// client-addressing (contract §3.1, vpn-setup.sh client block): the
		// probe client container for this attachment gets its claimed /24 at
		// host .2 on eth1 plus a default route via the attachment gateway.
		// Routed through Op.OnClient — the executor docker-execs it into the
		// container FABRIC_PROBE_MAP registers for "<node>/<logical-port>"
		// (executor-transport §4). eth0 is the container's mgmt veth and is
		// never touched. The ping itself stays the datapath check at first
		// activation (probe-ping), not part of these periodic checks.
		clientAddr, err := clientHostAddr(self.client)
		if err != nil {
			return nil, errf("client address for %s: %v", n, err)
		}
		probeAtt := n + "/" + self.logic
		np.Ops = append(np.Ops, Op{
			OnClient: probeAtt,
			Shell: []string{
				"ip addr flush dev eth1",
				fmt.Sprintf("ip addr add %s dev eth1", clientAddr),
				fmt.Sprintf("ip route replace default via %s dev eth1", strings.TrimSuffix(self.gw, "/24")),
			},
		})

		// checks, per the §3.1 Check column
		np.Checks = append(np.Checks,
			Check{Type: "redis-exists", RedisKey: "VRF|" + vrf, RedisDB: "4"},
			Check{Type: "ip-addr", Iface: self.port, Addr: self.gw},
			Check{Type: "ip-master", Iface: self.port, Master: vrf},
			// kernel-vrf-device: derived by the image from the /VRF row.
			Check{Type: "command", Command: "ip -br link show " + vrf, Expect: "UP"},
			// decap read-back (spike-vpn-readback-leaf01/leaf02): the kernel
			// prints the encap route with TWO spaces after the prefix
			// ("fcbb:bbbb:3:11::/64  encap seg6local action End.DT46 vrftable
			// 1001 dev Vrf1 metric 1024 pref medium"), so the Expect is that
			// receipt-literal substring — the executor's command check is a
			// raw strings.Contains of the live output, and the single-space
			// form written here before NEVER matched (a live check-failure
			// class, measured 2026-10-16).
			Check{Type: "command", Command: "ip -6 route show | grep seg6local", Expect: self.sid + "  encap seg6local action End.DT46"},
			// steering read-back (spike-vpn-readback-leaf02): the kernel prints
			// the segs list with count and brackets ("192.168.2.0/24  encap
			// seg6 mode encap segs 1 [ fcbb:bbbb:4:11:: ] dev Ethernet0 scope
			// link"); the bare "segs <sid>" form never matched.
			Check{Type: "command", Command: "ip route show vrf " + vrf + " | grep encap", Expect: "encap seg6 mode encap segs 1 [ " + peer.sidFn + " ]"},
			// /48 pin read-back (spike-steering-path).
			Check{Type: "command", Command: "ip -6 route show | grep 'metric 5'", Expect: peerLoc + " via " + pinLink},
			// client-addressing read-back (§3.1: client `ip -br addr show
			// eth1`), inside the probe client container.
			Check{Type: "ip-addr", Iface: "eth1", Addr: clientAddr, OnClient: probeAtt},
		)
		if steered && n == nodes[0] {
			np.Checks = append(np.Checks, Check{Type: "command",
				Command: "ip -6 route show",
				Expect:  peer.sidFn + " from :: via " + pinLink,
			})
		}

		// rollback, per §2b order (vpn-rollback.sh): kernel routes FIRST (the
		// as-built decap and any zebra static are separate routes for the
		// same prefix — one del removes exactly one, hence the recorded
		// loop-del), then the GCU removes, then the port flush.
		rbShell := []string{}
		if steered && n == nodes[0] {
			rbShell = append(rbShell,
				fmt.Sprintf("for i in 1 2 3 4 5; do ip -6 route del %s 2>/dev/null || break; done; true", peer.sidFn))
		}
		rbShell = append(rbShell,
			fmt.Sprintf("ip route del vrf %s %s 2>/dev/null; true", vrf, peer.client),
			fmt.Sprintf("for i in 1 2 3 4 5; do ip -6 route del %s 2>/dev/null || break; done; true", self.sid),
			fmt.Sprintf("ip -6 route del %s 2>/dev/null; true", peerLoc),
		)
		np.Rollback = append(np.Rollback,
			Op{Shell: rbShell},
			// attachment rollback: remove ONLY the rows the service owns,
			// field-level. A whole-table /INTERFACE remove without re-adding
			// the fabric link rows wipes the underlay (measured, vpn-rollback.sh);
			// the renderer carries no fabric link addresses, so it never
			// emits one — it removes the two access rows it added.
			Op{GCU: []map[string]any{
				{"op": "remove", "path": gwKey},
				{"op": "remove", "path": "/INTERFACE/" + self.port},
			}},
			// vrf-row rollback: own-process whole-table remove (GCU wedge
			// semantics; the kernel VRF device lingers — image behaviour).
			Op{GCU: []map[string]any{
				{"op": "remove", "path": "/VRF"},
			}},
			// client-addressing rollback, node-side half (see the package
			// comment): flush the attachment kernel port exactly as
			// vpn-rollback.sh flushes after the VRF detach.
			Op{Shell: []string{fmt.Sprintf("ip addr flush dev %s", self.port)}},
			// client-addressing rollback (§3.1: flush the port), inside the
			// probe client container — eth1 only, never the mgmt veth eth0.
			Op{Shell: []string{"ip addr flush dev eth1"}, OnClient: probeAtt},
		)

		plan.Nodes[n] = np
	}
	return plan, nil
}

// other returns the attachment node that is not n.
func other(nodes []string, n string) string {
	if nodes[0] == n {
		return nodes[1]
	}
	return nodes[0]
}

// gatewayAddr derives the attachment gateway address (host octet .1) from a
// client /24, as recorded in vrf-apply.sh (192.168.<svc>.1/24 on the port,
// client container at .2).
func gatewayAddr(prefix string) (string, error) {
	p, err := netip.ParsePrefix(prefix)
	if err != nil {
		return "", err
	}
	if !p.Addr().Is4() || p.Bits() != 24 {
		return "", errf("client prefix %q is not an IPv4 /24", prefix)
	}
	m := p.Masked().Addr().As4()
	m[3] = 1
	return fmt.Sprintf("%s/24", netip.AddrFrom4(m)), nil
}

// clientHostAddr derives the probe client container's address (host octet .2)
// from a client /24, as measured in data-model §8.7 (192.168.1.2/24 on
// srv6-client01 eth1, 192.168.2.2/24 on client02).
func clientHostAddr(prefix string) (string, error) {
	p, err := netip.ParsePrefix(prefix)
	if err != nil {
		return "", err
	}
	if !p.Addr().Is4() || p.Bits() != 24 {
		return "", errf("client prefix %q is not an IPv4 /24", prefix)
	}
	m := p.Masked().Addr().As4()
	m[3] = 2
	return fmt.Sprintf("%s/24", netip.AddrFrom4(m)), nil
}
