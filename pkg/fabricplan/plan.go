// SPDX-License-Identifier: Apache-2.0
// Package fabricplan renders Kubenet Network intent into per-node SONiC device
// operations for the fabric-executor.
//
// This is the southbound translation the SDC path was supposed to provide. It
// follows the ONLY write patterns proven on this fabric (see
// lab/profiles/sonic-vs/bootstrap/configure-fabric-bgp.sh and findings §4.1):
//
//   - VRF rows go through the GCU (whole-config YANG validation). Per-key adds
//     need the parent table to exist; the executor promotes a per-key add to a
//     whole-table add when the table is absent, exactly like the bootstrap.
//   - The overlay tables (VLAN, VXLAN_TUNNEL_MAP, EVPN_NVO) and anything the
//     image's YANG cannot express (VLAN_MEMBER against ports that are not in
//     the PORT table, INTERFACE rows, SVI addressing) are raw redis / kernel
//     writes. A GCU row for them would poison EVERY subsequent GCU write
//     image-wide, which is why this split is load-bearing, not stylistic.
//   - Attachment port naming is resolved by the caller through the site port
//     map (FABRIC_PORT_MAP): the spec's logical names (wan1, ethernet1) do not
//     exist as kernel devices.
//
// L3VNI-to-L3VLAN derivation: SONiC's VXLAN_TUNNEL_MAP requires a VLAN for
// every VNI, but VNI ids (kuid evpn-vni range 10000-20000) exceed the 12-bit
// VLAN space. The L3VLAN is derived deterministically into 4001-4094 — a band
// the kuid fabric-vlan index can never allocate (maxID 4000; 4001-4095 is the
// server's own reserved band), so a collision with an allocated L2 VLAN is
// impossible by construction.
package fabricplan

import (
	"fmt"
	"net/netip"
	"sort"
	"strings"

	"github.com/mairp/agentic-netops/pkg/kubenet"
)

// Plan is the full device work order for one Network.
type Plan struct {
	Nodes map[string]*NodePlan // logical node name -> plan
}

// NodePlan is one node's slice of the work order.
type NodePlan struct {
	Node     string  `json:"node"`
	Ops      []Op    `json:"ops"`
	Checks   []Check `json:"checks"`
	Rollback []Op    `json:"rollback,omitempty"` // applied on delete, best-effort
}

// Op is a single device operation. Exactly one field is set per op.
type Op struct {
	// GCU patch (JSON patch list, CONFIG_DB format).
	GCU []map[string]any `json:"gcu,omitempty"`
	// Redis commands, each run as `redis-cli -n 4 <cmd>` inside the node.
	Redis []string `json:"redis,omitempty"`
	// Plain shell commands (kernel state: links, bridge memberships, addresses).
	Shell []string `json:"shell,omitempty"`
	// vtysh commands (required running FRR state).
	VTYSh []string `json:"vtysh,omitempty"`
	// Append lines to /etc/frr/bgpd.conf (durable FRR state) if not present.
	FRRConf []string `json:"frrconf,omitempty"`
}

// Check verifies one piece of applied state on the node.
type Check struct {
	// redis-hget: KEY then FIELD, Expect exact match.
	RedisKey   string `json:"redisKey,omitempty"`
	RedisField string `json:"redisField,omitempty"`
	// redis-exists: key must exist in db 4.
	// ip-master: Iface must be enslaved to Master.
	Iface  string `json:"iface,omitempty"`
	Master string `json:"master,omitempty"`
	// ip-addr: Iface must carry Addr.
	Addr string `json:"addr,omitempty"`
	// bridge-vid: Iface must carry Vid in the Bridge (pvid or tagged).
	Vid int64 `json:"vid,omitempty"`
	// file-contains: Line must appear in Path.
	Path string `json:"path,omitempty"`
	Line string `json:"line,omitempty"`
	// Command is a read-only vtysh command for control-plane verification.
	Command string `json:"command,omitempty"`

	Expect string `json:"expect,omitempty"`
	Type   string `json:"type"`
}

// Error is a rendering failure that maps to a SchemaMismatch-style condition.
type Error struct{ Msg string }

func (e *Error) Error() string { return e.Msg }

func errf(format string, args ...any) error {
	return &Error{Msg: fmt.Sprintf(format, args...)}
}

// PortMapper resolves the spec's logical attachment names to kernel ports.
type PortMapper map[string]string

// normalizePortKey folds the notation an operator may use for one site port
// down to a single key: case and separators are spelling, not intent, so
// "Ethernet1", "ethernet-1" and "ethernet_1" all name the site's ethernet1.
// It never invents a mapping — only unifies spellings of an existing key.
func normalizePortKey(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// Known returns the logical names this site accepts, sorted — the only useful
// thing to tell an operator whose attachment name did not resolve.
func (m PortMapper) Known() []string {
	out := make([]string, 0, len(m))
	for k, v := range m {
		if v != "" {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// Port resolves a logical name; unknown names are an error, never a guess.
func (m PortMapper) Port(logical string) (string, error) {
	if p, ok := m[logical]; ok && p != "" {
		return p, nil
	}
	// Fall back to the normalized spelling. Sorted so a site map that spells
	// the same port two ways resolves deterministically rather than by map
	// iteration order.
	want := normalizePortKey(logical)
	for _, k := range m.Known() {
		if normalizePortKey(k) == want {
			return m[k], nil
		}
	}
	return "", errf("attachment %q not in site port map (site accepts: %s)", logical, strings.Join(m.Known(), ", "))
}

// Options carries the site-level knobs the renderer needs.
type Options struct {
	Ports PortMapper
	// BGPASN is the fabric ASN used for best-effort per-vrf FRR config.
	BGPASN string
	// VTEPName is the per-leaf VXLAN tunnel name (bootstrap default vtep1).
	VTEPName string
}

// ForNetwork renders the complete plan. L3VPN (routers+attachments with vrf)
// and L2VPN (bridgeDomains+attachments with vlan) may coexist; nodes with no
// actionable attachment are skipped.
func ForNetwork(net *kubenet.Network, opts Options) (*Plan, error) {
	if len(opts.Ports) == 0 {
		return nil, errf("site port map is empty")
	}
	if opts.VTEPName == "" {
		opts.VTEPName = "vtep1"
	}
	plan := &Plan{Nodes: map[string]*NodePlan{}}

	routers := map[string]kubenet.NetworkRouter{}
	for _, r := range net.Routers() {
		if r.Name == "" {
			return nil, errf("router with empty name")
		}
		routers[r.Name] = r
	}
	bds := map[int64]kubenet.BridgeDomain{}
	for _, bd := range net.BridgeDomains() {
		if bd.VLAN == 0 {
			continue
		}
		// 4001-4094 is the derived-L3VLAN band (see the package comment). A
		// service VLAN there would collide with some L3VNI's own VLAN, so it
		// is rejected as an intent-shape error rather than silently sharing.
		if bd.VLAN > l3VLANBase {
			return nil, errf("bridgeDomain %q uses vlan %d, reserved for derived L3VLANs (%d-4094); pick a vlan at or below %d",
				bd.Name, bd.VLAN, l3VLANBase+1, l3VLANBase)
		}
		bds[bd.VLAN] = bd
	}
	// Local VLANs: spec.vlans declares per-node local broadcast domains with no overlay.
	vls := map[int64]kubenet.NetworkVLAN{}
	for _, v := range net.VLANs() {
		if v.VLAN == 0 {
			continue
		}
		if v.VLAN > l3VLANBase {
			// Same message as bridgeDomains above (R-04): keep operator guidance consistent.
			return nil, errf("vlan %q uses vlan %d, reserved for derived L3VLANs (%d-4094); pick a vlan at or below %d",
				v.Name, v.VLAN, l3VLANBase+1, l3VLANBase)
		}
		vls[v.VLAN] = v
	}

	// Deterministic order for reproducible patches.
	atts := net.Attachments()
	sort.Slice(atts, func(i, j int) bool {
		if atts[i].Node != atts[j].Node {
			return atts[i].Node < atts[j].Node
		}
		return atts[i].Attachment < atts[j].Attachment
	})

	for _, att := range atts {
		np := plan.node(att.Node)
		switch {
		case att.VRF != "":
			r, ok := routers[att.VRF]
			if !ok {
				return nil, errf("attachment %s@%s references unknown router %q", att.Attachment, att.Node, att.VRF)
			}
			if err := renderL3(np, r, att, opts); err != nil {
				return nil, err
			}
		case att.VLAN != 0:
			if bd, ok := bds[att.VLAN]; ok {
				if bd.IRB == nil {
					if err := renderL2(np, bd, att, opts); err != nil {
						return nil, err
					}
					break
				}
				// Symmetric IRB: the bridge domain is the L2 half and its SVI is
				// the tenant gateway inside the router named by irb.vrf. Without
				// the router the routed half cannot be rendered, and rendering
				// only the L2 half would silently hand back a VPLS.
				r, ok := routers[bd.IRB.VRF]
				if !ok {
					return nil, errf("bridgeDomain %q declares irb.vrf %q with no matching router", bd.Name, bd.IRB.VRF)
				}
				if err := renderIRB(np, bd, r, att, opts); err != nil {
					return nil, err
				}
				break
			}
			// No bridgeDomain on this vlan — see if this is a local VLAN construct.
			if v, ok := vls[att.VLAN]; ok {
				if err := renderVLAN(np, v, att, opts); err != nil {
					return nil, err
				}
				break
			}
			return nil, errf("attachment %s@%s references vlan %d with no bridgeDomain or local VLAN (this network declares %s)",
				att.Attachment, att.Node, att.VLAN, declaredVLANs(bds, vls))
		default:
			return nil, errf("attachment %s@%s has neither vrf nor vlan", att.Attachment, att.Node)
		}
	}

	if len(plan.Nodes) == 0 {
		return nil, errf("network has no usable attachments")
	}
	return plan, nil
}

func (p *Plan) node(name string) *NodePlan {
	np, ok := p.Nodes[name]
	if !ok {
		np = &NodePlan{Node: name}
		p.Nodes[name] = np
	}
	return np
}

// l3VLANBase is the top of the allocatable L2 VLAN space: derived L3VLANs live
// at l3VLANBase+1 .. 4094, which the kuid fabric-vlan index can never hand out.
const l3VLANBase int64 = 4000

// L3VLANForVNI maps an L3VNI (kuid evpn-vni range) into the reserved 4001-4094
// VLAN band. See the package comment for why this band cannot collide.
func L3VLANForVNI(vni int64) (int64, error) {
	if vni < 10000 || vni > 14094 {
		return 0, errf("l3vni %d outside kuid evpn-vni range 10000-14094; cannot derive an L3VLAN", vni)
	}
	return l3VLANBase + (vni - 10000), nil
}

// declaredVLANs renders the bridge domains a network actually declares, so a
// mismatched attachment says what the operator could have meant.
func declaredVLANs(bds map[int64]kubenet.BridgeDomain, vls ...map[int64]kubenet.NetworkVLAN) string {
	if len(bds) == 0 && (len(vls) == 0 || len(vls[0]) == 0) {
		return "no bridgeDomains or vlans"
	}
	vlans := make([]int64, 0, len(bds))
	for v := range bds {
		vlans = append(vlans, v)
	}
	if len(vls) > 0 {
		for v := range vls[0] {
			vlans = append(vlans, v)
		}
	}
	sort.Slice(vlans, func(i, j int) bool { return vlans[i] < vlans[j] })
	parts := make([]string, 0, len(vlans))
	last := int64(-1)
	for _, v := range vlans {
		if v == last {
			continue
		}
		parts = append(parts, fmt.Sprintf("vlan %d", v))
		last = v
	}
	return strings.Join(parts, ", ")
}

// l3Context is the per-router device naming and identifiers that BOTH routed
// paths need — the L3VPN attachment and the routed half of a symmetric IRB.
// Deriving it in one place is what keeps apply, verify and rollback agreeing
// on every name (the derived VRF device name, the derived L3VLAN, the RD/RT).
type l3Context struct {
	VRFName   string // on-device VRF (DeviceVRFName)
	L3VNI     int64
	L3VLAN    int64
	L3VLANDev string // "Vlan<L3VLAN>"
	RD        string
	RT        string
}

func l3ContextFor(r kubenet.NetworkRouter) (l3Context, error) {
	if r.L3VNI == 0 {
		return l3Context{}, errf("router %q has no l3vni", r.Name)
	}
	// sonic-yang rejects VRF names over 16 characters (validated live:
	// "Invalid interface name length, it must not exceed 16 characters." for
	// vrf-bbae798efc224f7), and the intent tier happily generates vrf-<14 hex>
	// names. Derive a compliant device name deterministically — the same class
	// of contract as the port map (wan1 -> eth4): the intent keeps its name,
	// the device gets the derived one, everywhere consistently (GCU, kernel,
	// FRR, checks, rollback).
	vrfName, err := DeviceVRFName(r.Name)
	if err != nil {
		return l3Context{}, errf("router %q: %v", r.Name, err)
	}
	l3vlan, err := L3VLANForVNI(r.L3VNI)
	if err != nil {
		return l3Context{}, err
	}
	rt := firstRT(r.RouteTargets, r.RD)
	return l3Context{
		VRFName:   vrfName,
		L3VNI:     r.L3VNI,
		L3VLAN:    l3vlan,
		L3VLANDev: fmt.Sprintf("Vlan%d", l3vlan),
		RD:        rtRD(r.RD, rt),
		RT:        rt,
	}, nil
}

// vrfOp is the declared VRF intent through the GCU (per-key; the executor
// promotes it to a whole-table add when VRF does not exist yet — the
// bootstrap pattern).
func (c l3Context) vrfOp() Op {
	return Op{GCU: []map[string]any{
		{"op": "add", "path": fmt.Sprintf("/VRF/%s", c.VRFName), "value": map[string]string{"vni": fmt.Sprintf("%d", c.L3VNI)}},
	}}
}

// l3OverlayRedis writes the overlay rows the image's YANG cannot validate: the
// L3VNI's own VLAN and its tunnel map. A GCU row for these would poison every
// subsequent GCU write image-wide.
func (c l3Context) l3OverlayRedis(opts Options) []string {
	return []string{
		fmt.Sprintf("hset 'VLAN|%s' vlanid '%d'", c.L3VLANDev, c.L3VLAN),
		fmt.Sprintf("hset 'VXLAN_TUNNEL_MAP|%s|map_%d_%s' vni '%d' vlan '%s'", opts.VTEPName, c.L3VNI, c.L3VLANDev, c.L3VNI, c.L3VLANDev),
	}
}

// waitMaster enslaves iface to master, waiting for a device that a SONiC
// manager daemon creates asynchronously. vrfmgrd builds the VRF device from
// the CONFIG_DB row some seconds after the GCU write (observed: verify raced
// it and flipped Ready False/True), so this retries rather than firing blind;
// if the device never appears the verify checks fail loudly.
func waitMaster(iface, master string) string {
	// 30s, not 10: vrfmgrd's turnaround depends on how busy the device's
	// managers are, and a service applied while several others are
	// reconciling missed a 10 s window (observed: Vlan4033 never reached
	// Vrf-479b0e6e95 and the whole apply failed). Waiting longer costs
	// nothing when the device is already there — the loop exits on the first
	// success.
	return fmt.Sprintf("for i in $(seq 1 30); do ip link set %s master %s 2>/dev/null && exit 0; sleep 1; done; exit 1", iface, master)
}

// sviShell builds the kernel plumbing for one SVI: the Vlan subdevice of the
// vlan-aware Bridge, enslaved to the VRF and brought up. CONFIG_DB
// INTERFACE/VLAN rows for Vlan devices would poison GCU (YANG leafref), so
// the data path is kernel-side, following the bootstrap pattern the fabric
// already runs.
func sviShell(dev string, vid int64, vrfName string, addrs []string) []string {
	shell := []string{
		"ip link show Bridge >/dev/null 2>&1 || { ip link add Bridge type bridge; ip link set Bridge up; }",
		// vlanmgrd owns the Vlan device. It builds it from the CONFIG_DB VLAN
		// row and only then marks the vlan ready in STATE_DB — which is what
		// vxlanmgrd waits on before building the VXLAN device. Creating the
		// device ourselves first makes vlanmgrd's own create fail, and it does
		// NOT retry: the vlan never becomes ready and the vtep is never built
		// at all (observed live — Vlan115 present, no VLAN_TABLE|Vlan115, no
		// vtep1-115, service dead; the identical L3 path had simply been
		// losing that race and getting away with it). So wait for the manager,
		// and build the device ourselves only if it never appears.
		fmt.Sprintf("for i in $(seq 1 15); do ip link show %s >/dev/null 2>&1 && break; sleep 1; done; "+
			"ip link show %s >/dev/null 2>&1 || ip link add %s link Bridge type vlan id %d", dev, dev, dev, vid),
		waitMaster(dev, vrfName),
		fmt.Sprintf("ip link set %s up", dev),
		// The Bridge's own vlan entry, so the SVI sees the vlan's traffic.
		fmt.Sprintf("bridge vlan add dev Bridge vid %d self 2>/dev/null || true", vid),
	}
	for _, addr := range addrs {
		if addr == "" {
			continue
		}
		shell = append(shell,
			fmt.Sprintf("ip -br addr show %s 2>/dev/null | grep -qF '%s' || ip addr add %s dev %s", dev, addr, addr, dev))
	}
	return shell
}

// accessPortShell joins one physical port to the vlan-aware Bridge in a
// service vlan. Ports are shared: several services can attach to one physical
// port, so the port is a Bridge port (never a VRF slave — a device has one
// master, and two services on wan1 fought over it, observed live as
// flip-flopping ApplyFailed). The untagged/PVID role is claimed only when no
// service holds it yet; a later service on the same port lands tagged instead
// of stealing the first one's untagged traffic.
func accessPortShell(port string, vid int64) []string {
	return []string{
		// Move off any VRF master first (the old per-port master model).
		fmt.Sprintf("ip link show %s | grep -q 'master Bridge' || { ip link set %s nomaster 2>/dev/null || true; ip link set %s master Bridge; }", port, port, port),
		// The default vlan is not a service; drop it so a service vlan can be
		// the untagged one.
		fmt.Sprintf("bridge vlan del dev %s vid 1 2>/dev/null || true", port),
		// `bridge vlan show` marks the untagged default with the literal word
		// PVID. An earlier JSON probe read a "PVID" key that iproute2 never
		// emits (the flags are a list), so it always concluded "no PVID" and
		// every new service stole the untagged role from the previous one.
		fmt.Sprintf("if bridge vlan show dev %s 2>/dev/null | grep -qw PVID; then bridge vlan add dev %s vid %d 2>/dev/null || true; else bridge vlan add dev %s vid %d pvid untagged 2>/dev/null || true; fi", port, port, vid, port, vid),
		fmt.Sprintf("ip link set %s up 2>/dev/null || true", port),
	}
}

// vtepShell waits for the VXLAN device SONiC's vxlanmgrd builds from the
// tunnel-map row and makes sure it is a Bridge port in the service vlan.
// The device is named after the VLAN, NOT the VNI (vni 1000 lands as
// vtep1-2000): naming it after the VNI made every one of these commands a
// silent no-op against a device that does not exist. vxlanmgrd usually does
// this itself but does not always win the race against Bridge (observed:
// leaf01 had vtep1-100 with no master while leaf02 had it bridged).
func vtepShell(vtep string, vid int64) []string {
	dev := fmt.Sprintf("%s-%d", vtep, vid)
	return []string{
		fmt.Sprintf("for i in $(seq 1 15); do ip link show %s >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1", dev),
		// Every write here is guarded on the state being wrong. A converged
		// service is reconciled repeatedly, and re-issuing bridge membership
		// on a healthy VXLAN device churns netlink for no reason — churn
		// zebra and bgpd notice.
		fmt.Sprintf("ip -d link show %s 2>/dev/null | grep -q 'master Bridge' || ip link set %s master Bridge 2>/dev/null || true", dev, dev),
		fmt.Sprintf("bridge vlan show dev %s 2>/dev/null | grep -qE '(^| )1( |$)' && bridge vlan del dev %s vid 1 2>/dev/null; true", dev, dev),
		fmt.Sprintf("bridge vlan show dev %s 2>/dev/null | grep -qw %d || bridge vlan add dev %s vid %d pvid untagged 2>/dev/null || true", dev, vid, dev, vid),
		fmt.Sprintf("ip link show %s 2>/dev/null | grep -q 'state UNKNOWN\\|state UP' || ip link set %s up 2>/dev/null || true", dev, dev),
	}
}

// evpnVNIAdoptionShell re-triggers bgpd's adoption of an L3VNI when it has not
// happened. zebra can know a VNI while bgpd does not — observed live on a
// service that had a correct VRF row, SVI, bridged VXLAN device and
// `vrf X / vni N` in FRR, and still answered "VNI not found" to
// `show bgp l2vpn evpn vni N`. Re-issuing the binding fixes it, so a reconcile
// heals the service instead of failing the same check forever. Guarded: on a
// healthy service this reads state and writes nothing.
func (c l3Context) evpnVNIAdoptionShell() []string {
	return []string{fmt.Sprintf(
		"vtysh -c 'show bgp l2vpn evpn vni %d' 2>/dev/null | grep -q 'Tenant VRF: %s' || { "+
			"vtysh -c 'conf t' -c 'vrf %s' -c 'no vni %d' -c 'end'; sleep 2; "+
			"vtysh -c 'conf t' -c 'vrf %s' -c 'vni %d' -c 'end'; sleep 3; }",
		c.L3VNI, c.VRFName, c.VRFName, c.L3VNI, c.VRFName, c.L3VNI)}
}

// frrOps returns the running (vtysh) and durable (bgpd.conf) FRR state that
// binds the L3VNI to the VRF and originates the service's connected prefixes
// as EVPN Type-5. The clean 202505 image supports this path, so it is part of
// the required convergence contract, not a best-effort operation.
func (c l3Context) frrOps(afis []string, asn string) (Op, Op) {
	vty := []string{
		"conf t",
		fmt.Sprintf("vrf %s", c.VRFName),
		fmt.Sprintf("vni %d", c.L3VNI),
		"exit-vrf",
		fmt.Sprintf("router bgp %s vrf %s", asnOr(asn, "65000"), c.VRFName),
		"no bgp ebgp-requires-policy",
	}
	frr := []string{
		fmt.Sprintf("vrf %s", c.VRFName),
		fmt.Sprintf(" vni %d", c.L3VNI),
		"exit-vrf",
		"!",
		fmt.Sprintf("router bgp %s vrf %s", asnOr(asn, "65000"), c.VRFName),
		" no bgp ebgp-requires-policy",
	}
	for _, afi := range afis {
		vty = append(vty,
			fmt.Sprintf("address-family %s", afi),
			"redistribute connected",
			"exit-address-family",
		)
		frr = append(frr,
			fmt.Sprintf(" address-family %s", afi),
			"  redistribute connected",
			" exit-address-family",
			" !",
		)
	}
	vty = append(vty, "address-family l2vpn evpn")
	frr = append(frr, " address-family l2vpn evpn")
	for _, afi := range afis {
		vty = append(vty, fmt.Sprintf("advertise %s", afi))
		frr = append(frr, fmt.Sprintf("  advertise %s", afi))
	}
	if c.RD != "" {
		vty = append(vty, fmt.Sprintf("rd %s", c.RD))
		frr = append(frr, fmt.Sprintf("  rd %s", c.RD))
	}
	if c.RT != "" {
		vty = append(vty, fmt.Sprintf("route-target both %s", c.RT))
		frr = append(frr, fmt.Sprintf("  route-target both %s", c.RT))
	}
	vty = append(vty, "exit-address-family", "end")
	frr = append(frr, " exit-address-family", "!")
	return Op{VTYSh: vty}, Op{FRRConf: frr}
}

// l3Checks verifies the declared rows and the routed plumbing common to the
// L3VPN and IRB paths.
func (c l3Context) l3Checks(opts Options) []Check {
	vtep := fmt.Sprintf("%s-%d", opts.VTEPName, c.L3VLAN)
	return []Check{
		{Type: "redis-hget", RedisKey: fmt.Sprintf("VRF|%s", c.VRFName), RedisField: "vni", Expect: fmt.Sprintf("%d", c.L3VNI)},
		{Type: "redis-exists", RedisKey: fmt.Sprintf("VXLAN_TUNNEL_MAP|%s|map_%d_%s", opts.VTEPName, c.L3VNI, c.L3VLANDev)},
		{Type: "ip-master", Iface: c.L3VLANDev, Master: c.VRFName},
		// The L3VNI's own VXLAN device, bridged into the derived L3VLAN and
		// carrying this service's VNI: without it the VRF has a control plane
		// and no symmetric-IRB data path between VTEPs.
		{Type: "ip-master", Iface: vtep, Master: "Bridge"},
		{Type: "link-vxlan-id", Iface: vtep, Expect: fmt.Sprintf("%d", c.L3VNI)},
		{Type: "vtysh-contains", Command: fmt.Sprintf("show bgp l2vpn evpn vni %d", c.L3VNI), Expect: "Tenant VRF: " + c.VRFName},
	}
}

// type5Checks asserts the service's own prefixes are locally originated as
// EVPN Type-5 routes.
func (c l3Context) type5Checks(prefixes []string) ([]Check, error) {
	var checks []Check
	for _, prefix := range prefixes {
		if prefix == "" {
			continue
		}
		needle, err := type5RouteNeedle(prefix)
		if err != nil {
			return nil, errf("invalid prefix %q: %v", prefix, err)
		}
		command := "show bgp l2vpn evpn route type prefix self-originate"
		if c.RD != "" {
			// Scope the lookup by RD. Multiple services can intentionally expose
			// the same prefix; a global lookup would let one service mask another
			// service's missing local Type-5 route.
			command = "show bgp l2vpn evpn route rd " + c.RD
		}
		checks = append(checks, Check{Type: "vtysh-contains", Command: command, Expect: needle})
	}
	return checks, nil
}

// afiFor names the address family of a prefix list, in the order FRR wants it.
func afisFor(prefixes []string) ([]string, error) {
	var v4, v6 bool
	for _, p := range prefixes {
		if p == "" {
			continue
		}
		parsed, err := netip.ParsePrefix(p)
		if err != nil {
			return nil, errf("invalid prefix %q: %v", p, err)
		}
		if parsed.Addr().Is6() {
			v6 = true
		} else {
			v4 = true
		}
	}
	var afis []string
	if v4 {
		afis = append(afis, "ipv4 unicast")
	}
	if v6 {
		afis = append(afis, "ipv6 unicast")
	}
	if len(afis) == 0 {
		afis = []string{"ipv4 unicast"}
	}
	return afis, nil
}

func renderL3(np *NodePlan, r kubenet.NetworkRouter, att kubenet.NetworkAttachment, opts Options) error {
	c, err := l3ContextFor(r)
	if err != nil {
		return err
	}
	port, err := opts.Ports.Port(att.Attachment)
	if err != nil {
		return errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
	}
	afis, err := afisFor(r.Prefixes)
	if err != nil {
		return errf("router %q: %v", r.Name, err)
	}

	// 1. Declared VRF intent through the GCU.
	np.Ops = append(np.Ops, c.vrfOp())
	// 2. Overlay rows the image cannot validate.
	np.Ops = append(np.Ops, Op{Redis: c.l3OverlayRedis(opts)})
	// 3. Kernel state: the L3VNI's SVI carries the service prefix, and the
	//    attachment port joins the Bridge in that same vlan.
	var addrs []string
	if len(r.Prefixes) > 0 {
		addrs = append(addrs, sviAddr(r.Prefixes[0]))
	}
	shell := sviShell(c.L3VLANDev, c.L3VLAN, c.VRFName, addrs)
	shell = append(shell, accessPortShell(port, c.L3VLAN)...)
	shell = append(shell, vtepShell(opts.VTEPName, c.L3VLAN)...)
	np.Ops = append(np.Ops, Op{Shell: shell})
	// 4. FRR: bind the L3VNI to the VRF and originate the connected prefixes.
	vty, frr := c.frrOps(afis, opts.BGPASN)
	np.Ops = append(np.Ops, vty, frr, Op{Shell: c.evpnVNIAdoptionShell()})

	// Verification: declared rows present, kernel plumbing in place.
	np.Checks = append(np.Checks, c.l3Checks(opts)...)
	np.Checks = append(np.Checks,
		// The port is an ACCESS bridge port in the service vlan, not a VRF
		// slave — one physical port can carry several services this way.
		Check{Type: "bridge-vid", Iface: port, Vid: c.L3VLAN},
	)
	if len(r.Prefixes) > 0 {
		type5, err := c.type5Checks(r.Prefixes[:1])
		if err != nil {
			return errf("router %q: %v", r.Name, err)
		}
		np.Checks = append(np.Checks, Check{Type: "ip-addr", Iface: c.L3VLANDev, Addr: sviAddr(r.Prefixes[0])})
		np.Checks = append(np.Checks, type5...)
	}

	// Rollback: withdraw the declared rows and let each device's own manager
	// remove the device. NEVER `ip link del` a Vlan device here — vlanmgrd
	// owns it, and when it later runs its own delete and finds the device
	// gone it treats the failure as fatal and EXITS (observed live:
	// `Cannot find device "Vlan4031"` ... `exited: vlanmgrd (exit status
	// 255)`), after which no VLAN on that node is provisioned again until
	// someone restarts it. Deleting one service that way broke every L2
	// service the fabric would have built afterwards.
	np.Rollback = append(np.Rollback,
		Op{Redis: []string{
			fmt.Sprintf("del 'VXLAN_TUNNEL_MAP|%s|map_%d_%s'", opts.VTEPName, c.L3VNI, c.L3VLANDev),
			fmt.Sprintf("del 'VLAN|%s'", c.L3VLANDev),
		}},
		Op{Shell: []string{
			// The port's vlan membership is ours, not a manager's.
			fmt.Sprintf("bridge vlan del dev %s vid %d 2>/dev/null || true", port, c.L3VLAN),
		}},
		Op{GCU: []map[string]any{{"op": "remove", "path": fmt.Sprintf("/VRF/%s", c.VRFName)}}},
	)
	return nil
}

// DeviceVRFName derives the on-device VRF name from the intent's router name.
// sonic-vrf.yang forces names to match ^Vrf[a-zA-Z0-9_-]+$ AND caps them at
// 16 characters (both validated live: "Invalid interface name length" for the
// 19-char vrf-bbae798efc224f7, then "Invalid VRF name" for the lowercase
// vrf-bbae798efc). The derivation: strip a leading "vrf-" (case-insensitive),
// sanitize to the YANG alphabet, cap the remainder at 10, prefix "Vrf-".
// Deterministic — every render of the same intent derives the same name, so
// apply, verify and rollback all agree; the same class of contract as the
// port map (wan1 -> eth4).
func DeviceVRFName(intentName string) (string, error) {
	if intentName == "" {
		return "", fmt.Errorf("empty vrf name")
	}
	rest := intentName
	if len(rest) > 4 && strings.EqualFold(rest[:4], "vrf-") {
		rest = rest[4:]
	}
	var b strings.Builder
	for _, r := range rest {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		}
	}
	rest = b.String()
	if rest == "" {
		return "", fmt.Errorf("vrf name %q derives to no usable characters", intentName)
	}
	// Cap total length at 14 ("Vrf-" + 10): the effective YANG limit is
	// actually BELOW 16 despite the error text ("Vrf-bbae798efc22", exactly
	// 16, still fails Data Loading; 14 passes — both validated live).
	if len(rest) > 10 {
		rest = rest[:10]
	}
	return "Vrf-" + rest, nil
}

// l2Overlay writes the bridge domain's own overlay rows (raw redis — the same
// table family as the bootstrap's Vlan100). vxlanmgrd turns the tunnel-map row
// into the vtep1-<vlan> device.
func l2Overlay(bd kubenet.BridgeDomain, vlanName string, opts Options) []string {
	return []string{
		fmt.Sprintf("hset 'VLAN|%s' vlanid '%d'", vlanName, bd.VLAN),
		fmt.Sprintf("hset 'VXLAN_TUNNEL_MAP|%s|map_%d_%s' vni '%d' vlan '%s'", opts.VTEPName, bd.L2VNI, vlanName, bd.L2VNI, vlanName),
	}
}

// renderVLAN renders a local VLAN construct: a VLAN row and the access port's membership
// in the vlan-aware Bridge. No VXLAN_TUNNEL_MAP rows, no vtep handling, no l2vpn evpn block.
func renderVLAN(np *NodePlan, v kubenet.NetworkVLAN, att kubenet.NetworkAttachment, opts Options) error {
	vlanName := fmt.Sprintf("Vlan%d", v.VLAN)
	port, err := opts.Ports.Port(att.Attachment)
	if err != nil {
		return errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
	}
	// 1. Declared VLAN row (raw redis) only.
	np.Ops = append(np.Ops, Op{Redis: []string{fmt.Sprintf("hset 'VLAN|%s' vlanid '%d'", vlanName, v.VLAN)}})
	// 2. Kernel: join the access port to the Bridge in this vlan; no VXLAN device involvement.
	shell := []string{"ip link show Bridge >/dev/null 2>&1 || { ip link add Bridge type bridge; ip link set Bridge up; }"}
	shell = append(shell, accessPortShell(port, v.VLAN)...)
	np.Ops = append(np.Ops, Op{Shell: shell})
	// 3. Verification: VLAN row present and port membership + bridge vid.
	np.Checks = append(np.Checks,
		Check{Type: "redis-hget", RedisKey: fmt.Sprintf("VLAN|%s", vlanName), RedisField: "vlanid", Expect: fmt.Sprintf("%d", v.VLAN)},
		Check{Type: "ip-master", Iface: port, Master: "Bridge"},
		Check{Type: "bridge-vid", Iface: port, Vid: v.VLAN},
	)
	// 4. Rollback: delete VLAN row and remove port membership.
	np.Rollback = append(np.Rollback,
		Op{Redis: []string{fmt.Sprintf("del 'VLAN|%s'", vlanName)}},
		Op{Shell: []string{fmt.Sprintf("bridge vlan del dev %s vid %d 2>/dev/null || true", port, v.VLAN)}},
	)
	return nil
}

// l2RT is the bridge domain's route target, or "" when it declares none.
func l2RT(bd kubenet.BridgeDomain) string {
	var rts *kubenet.RouteTargets
	if bd.EVPN != nil {
		rts = bd.EVPN.RouteTargets
	}
	return firstRT(rts, "")
}

// l2EVPNOp wires the L2VNI's RD/RT under address-family l2vpn evpn.
//
// That address family lives inside the node's own DEFAULT BGP instance, whose
// ASN is the leaf's fabric eBGP ASN (65101/65102 here) — not the 65000 the
// routed path uses for its per-VRF instances. `router bgp` with no ASN is
// refused outright ("Please specify ASN and VRF") and a guessed ASN would
// quietly build a second, wrong instance, so the node is asked for its own:
// this is a shell op rather than a vtysh op precisely because the ASN has to
// be discovered on the device before the vtysh call is made.
//
// Sending `address-family l2vpn evpn` straight to vtysh at top level — what
// this did before any VPLS ever rendered — is simply not a command there:
// "% Unknown command: address-family l2vpn evpn".
func l2EVPNOp(bd kubenet.BridgeDomain) (Op, bool) {
	rt := l2RT(bd)
	if rt == "" {
		return Op{}, false
	}
	discover := "asn=$(vtysh -c 'show running-config' | awk '/^router bgp [0-9]+$/{print $3; exit}'); " +
		"[ -n \"$asn\" ] || { echo 'no default bgp instance on this node'; exit 1; }"
	running := fmt.Sprintf(
		"vtysh -c 'conf t' -c \"router bgp $asn\" -c 'address-family l2vpn evpn' -c 'vni %d' "+
			"-c 'rd %s' -c 'route-target import %s' -c 'route-target export %s' -c 'exit-vni' "+
			"-c 'exit-address-family' -c 'end'",
		bd.L2VNI, rt, rt, rt)
	// Durable half: the same block appended to bgpd.conf. FRR merges repeated
	// `router bgp <same asn>` blocks, so appending re-enters the instance.
	durable := fmt.Sprintf(
		"grep -qF '  vni %d' /etc/frr/bgpd.conf || "+
			"printf 'router bgp %%s\\n address-family l2vpn evpn\\n  vni %d\\n   rd %s\\n"+
			"   route-target import %s\\n   route-target export %s\\n  exit-vni\\n exit-address-family\\n!\\n' "+
			"\"$asn\" >> /etc/frr/bgpd.conf",
		bd.L2VNI, bd.L2VNI, rt, rt, rt)
	return Op{Shell: []string{discover + "\n" + running + "\n" + durable}}, true
}

// l2Checks verifies the declared rows and the L2 data path: the access port
// AND the VXLAN device both have to be Bridge ports in the service vlan, or
// the bridge domain is local-only while reporting success.
func l2Checks(bd kubenet.BridgeDomain, vlanName, port string, opts Options) []Check {
	checks := []Check{
		{Type: "redis-exists", RedisKey: fmt.Sprintf("VXLAN_TUNNEL|%s", opts.VTEPName)},
		{Type: "redis-hget", RedisKey: fmt.Sprintf("VLAN|%s", vlanName), RedisField: "vlanid", Expect: fmt.Sprintf("%d", bd.VLAN)},
		{Type: "redis-exists", RedisKey: fmt.Sprintf("VXLAN_TUNNEL_MAP|%s|map_%d_%s", opts.VTEPName, bd.L2VNI, vlanName)},
		{Type: "ip-master", Iface: port, Master: "Bridge"},
		{Type: "bridge-vid", Iface: port, Vid: bd.VLAN},
		{Type: "ip-master", Iface: fmt.Sprintf("%s-%d", opts.VTEPName, bd.VLAN), Master: "Bridge"},
		{Type: "bridge-vid", Iface: fmt.Sprintf("%s-%d", opts.VTEPName, bd.VLAN), Vid: bd.VLAN},
		// ... and that it carries THIS service's VNI. The device is named after
		// the VLAN, so a service that reuses a VLAN another service already
		// holds inherits that service's device: every membership check passes
		// while the overlay carries the other VNI (observed live, leaf01
		// vtep1-300 on vni 10021 for a service allocated 10022).
		{Type: "link-vxlan-id", Iface: fmt.Sprintf("%s-%d", opts.VTEPName, bd.VLAN), Expect: fmt.Sprintf("%d", bd.L2VNI)},
	}
	// When the domain declares a route target, BGP has to know the L2VNI by
	// it: the CONFIG_DB rows alone prove a local bridge, not an EVPN service.
	if rt := l2RT(bd); rt != "" {
		checks = append(checks, Check{
			Type:    "vtysh-contains",
			Command: fmt.Sprintf("show bgp l2vpn evpn vni %d", bd.L2VNI),
			Expect:  "RD: " + rt,
		})
	}
	return checks
}

// l2Rollback removes what the L2 half owns. The VXLAN device belongs to
// vxlanmgrd, which withdraws it when the tunnel-map row goes away, so the
// rollback deletes the row and leaves the device to its owner.
func l2Rollback(bd kubenet.BridgeDomain, vlanName, port string, opts Options) []Op {
	return []Op{
		{Redis: []string{
			fmt.Sprintf("del 'VXLAN_TUNNEL_MAP|%s|map_%d_%s'", opts.VTEPName, bd.L2VNI, vlanName),
			fmt.Sprintf("del 'VLAN|%s'", vlanName),
		}},
		{Shell: []string{
			fmt.Sprintf("bridge vlan del dev %s vid %d 2>/dev/null || true", port, bd.VLAN),
		}},
	}
}

func renderL2(np *NodePlan, bd kubenet.BridgeDomain, att kubenet.NetworkAttachment, opts Options) error {
	if bd.L2VNI == 0 {
		return errf("bridgeDomain %q has no l2vni", bd.Name)
	}
	vlanName := fmt.Sprintf("Vlan%d", bd.VLAN)
	port, err := opts.Ports.Port(att.Attachment)
	if err != nil {
		return errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
	}

	np.Ops = append(np.Ops, Op{Redis: l2Overlay(bd, vlanName, opts)})

	// Kernel: the access port and the L2VNI's VXLAN device both join the
	// vlan-aware Bridge in the service vlan.
	shell := []string{"ip link show Bridge >/dev/null 2>&1 || { ip link add Bridge type bridge; ip link set Bridge up; }"}
	shell = append(shell, accessPortShell(port, bd.VLAN)...)
	shell = append(shell, vtepShell(opts.VTEPName, bd.VLAN)...)
	np.Ops = append(np.Ops, Op{Shell: shell})

	if op, ok := l2EVPNOp(bd); ok {
		np.Ops = append(np.Ops, op)
	}

	np.Checks = append(np.Checks, l2Checks(bd, vlanName, port, opts)...)
	np.Rollback = append(np.Rollback, l2Rollback(bd, vlanName, port, opts)...)
	return nil
}

// renderIRB renders a symmetric IRB service: the bridge domain's L2 half
// exactly as renderL2 builds it, plus the routed half — the domain's SVI is
// the tenant gateway and lives inside the router named by irb.vrf, which
// carries its own L3VNI. Rendering only the L2 half (what happened while
// kubenet.BridgeDomain had no irb field) silently hands the operator a VPLS.
func renderIRB(np *NodePlan, bd kubenet.BridgeDomain, r kubenet.NetworkRouter, att kubenet.NetworkAttachment, opts Options) error {
	if bd.L2VNI == 0 {
		return errf("bridgeDomain %q has no l2vni", bd.Name)
	}
	c, err := l3ContextFor(r)
	if err != nil {
		return err
	}
	vlanName := fmt.Sprintf("Vlan%d", bd.VLAN)
	port, err := opts.Ports.Port(att.Attachment)
	if err != nil {
		return errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
	}
	gateways := []string{bd.IRB.GatewayV4, bd.IRB.GatewayV6}
	afis, err := afisFor(gateways)
	if err != nil {
		return errf("bridgeDomain %q: %v", bd.Name, err)
	}

	// 1. Declared VRF intent (GCU) — the routed half's identity.
	np.Ops = append(np.Ops, c.vrfOp())
	// 2. Overlay rows: the bridge domain's L2VNI and the router's L3VNI.
	np.Ops = append(np.Ops, Op{Redis: append(l2Overlay(bd, vlanName, opts), c.l3OverlayRedis(opts)...)})
	// 3. Kernel: the L3VNI's own SVI (no address — it is the symmetric-IRB
	//    transit vlan), then the bridge domain's SVI carrying the tenant
	//    gateway inside the VRF, then the access port and the L2VNI's VXLAN
	//    device in the service vlan.
	shell := sviShell(c.L3VLANDev, c.L3VLAN, c.VRFName, nil)
	shell = append(shell, sviShell(vlanName, bd.VLAN, c.VRFName, gateways)...)
	shell = append(shell, accessPortShell(port, bd.VLAN)...)
	shell = append(shell, vtepShell(opts.VTEPName, bd.VLAN)...)
	np.Ops = append(np.Ops, Op{Shell: shell})
	// 4. FRR: the L2VNI's RD/RT, then the VRF's L3VNI and its Type-5 origination.
	if op, ok := l2EVPNOp(bd); ok {
		np.Ops = append(np.Ops, op)
	}
	vty, frr := c.frrOps(afis, opts.BGPASN)
	np.Ops = append(np.Ops, vty, frr, Op{Shell: c.evpnVNIAdoptionShell()})

	np.Checks = append(np.Checks, l2Checks(bd, vlanName, port, opts)...)
	np.Checks = append(np.Checks, c.l3Checks(opts)...)
	// The gateway SVI is the whole point of an IRB: it must be in the VRF and
	// carry every declared gateway address.
	np.Checks = append(np.Checks, Check{Type: "ip-master", Iface: vlanName, Master: c.VRFName})
	for _, gw := range gateways {
		if gw != "" {
			np.Checks = append(np.Checks, Check{Type: "ip-addr", Iface: vlanName, Addr: gw})
		}
	}
	type5, err := c.type5Checks(gateways)
	if err != nil {
		return errf("bridgeDomain %q: %v", bd.Name, err)
	}
	np.Checks = append(np.Checks, type5...)

	np.Rollback = append(np.Rollback, l2Rollback(bd, vlanName, port, opts)...)
	// Same rule as the L3VPN rollback: withdraw the rows, never delete a
	// device a SONiC manager owns.
	np.Rollback = append(np.Rollback,
		Op{Redis: []string{
			fmt.Sprintf("del 'VXLAN_TUNNEL_MAP|%s|map_%d_%s'", opts.VTEPName, c.L3VNI, c.L3VLANDev),
			fmt.Sprintf("del 'VLAN|%s'", c.L3VLANDev),
		}},
		Op{GCU: []map[string]any{{"op": "remove", "path": fmt.Sprintf("/VRF/%s", c.VRFName)}}},
	)
	return nil
}

// --- small helpers -----------------------------------------------------------

// sviAddr derives the SVI address from a declared prefix: first usable host
// (x.y.z.1/n) — the same convention the bootstrap used for VrfBlue's Vlan2000.
func sviAddr(prefix string) string {
	parts := strings.Split(prefix, "/")
	if len(parts) != 2 {
		return prefix
	}
	o := strings.Split(parts[0], ".")
	if len(o) == 4 {
		o[3] = "1"
		return strings.Join(o, ".") + "/" + parts[1]
	}
	// v6 or non-dotted: keep the network address itself.
	return prefix
}

// type5RouteNeedle returns FRR's canonical Type-5 NLRI rendering for a service
// prefix. Masking prevents host bits in user input from making verification
// look for a route FRR necessarily normalizes to the network address.
func type5RouteNeedle(prefix string) (string, error) {
	p, err := netip.ParsePrefix(prefix)
	if err != nil {
		return "", err
	}
	p = p.Masked()
	return fmt.Sprintf("[5]:[0]:[%d]:[%s]", p.Bits(), p.Addr()), nil
}

func firstRT(rts *kubenet.RouteTargets, fallbackRD string) string {
	if rts != nil {
		if len(rts.Export) > 0 {
			return rts.Export[0]
		}
		if len(rts.Import) > 0 {
			return rts.Import[0]
		}
	}
	return fallbackRD
}

func rtRD(rd, rt string) string {
	if rd != "" {
		return rd
	}
	return rt
}

func asnOr(asn, def string) string {
	if asn != "" {
		return asn
	}
	return def
}
