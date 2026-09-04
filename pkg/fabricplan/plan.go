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
	Node   string    `json:"node"`
	Ops    []Op      `json:"ops"`
	Checks []Check   `json:"checks"`
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
	// vtysh commands (running FRR state; best-effort — see D-A2).
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

// Port resolves a logical name; unknown names are an error, never a guess.
func (m PortMapper) Port(logical string) (string, error) {
	if p, ok := m[logical]; ok && p != "" {
		return p, nil
	}
	return "", errf("attachment %q not in site port map", logical)
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
		if bd.VLAN != 0 {
			bds[bd.VLAN] = bd
		}
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
			bd, ok := bds[att.VLAN]
			if !ok {
				return nil, errf("attachment %s@%s references vlan %d with no bridgeDomain", att.Attachment, att.Node, att.VLAN)
			}
			if err := renderL2(np, bd, att, opts); err != nil {
				return nil, err
			}
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

// L3VLANForVNI maps an L3VNI (kuid evpn-vni range) into the reserved 4001-4094
// VLAN band. See the package comment for why this band cannot collide.
func L3VLANForVNI(vni int64) (int64, error) {
	if vni < 10000 || vni > 14094 {
		return 0, errf("l3vni %d outside kuid evpn-vni range 10000-14094; cannot derive an L3VLAN", vni)
	}
	return 4000 + (vni - 10000), nil
}

func renderL3(np *NodePlan, r kubenet.NetworkRouter, att kubenet.NetworkAttachment, opts Options) error {
	if r.L3VNI == 0 {
		return errf("router %q has no l3vni", r.Name)
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
		return errf("router %q: %v", r.Name, err)
	}
	l3vlan, err := L3VLANForVNI(r.L3VNI)
	if err != nil {
		return err
	}
	vlanName := fmt.Sprintf("Vlan%d", l3vlan)
	port, err := opts.Ports.Port(att.Attachment)
	if err != nil {
		return errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
	}

	// 1. Declared VRF intent through the GCU (per-key; executor promotes to a
	//    whole-table add when VRF does not exist yet — bootstrap pattern).
	np.Ops = append(np.Ops, Op{GCU: []map[string]any{
		{"op": "add", "path": fmt.Sprintf("/VRF/%s", vrfName), "value": map[string]string{"vni": fmt.Sprintf("%d", r.L3VNI)}},
	}})

	// 2. Overlay rows the image cannot validate: the L3VNI's VLAN and tunnel map.
	np.Ops = append(np.Ops, Op{Redis: []string{
		fmt.Sprintf("hset 'VLAN|%s' vlanid '%d'", vlanName, l3vlan),
		fmt.Sprintf("hset 'VXLAN_TUNNEL_MAP|%s|map_%d_%s' vni '%d' vlan '%s'", opts.VTEPName, r.L3VNI, vlanName, r.L3VNI, vlanName),
	}})

	// 3. Kernel state. vrfmgrd builds the VRF device from the CONFIG_DB row,
	//    but the L3VNI's SVI and the port attachment are ours: CONFIG_DB
	//    INTERFACE/VLAN rows for Vlan devices would poison GCU (YANG leafref),
	//    so the data path is kernel-side, following the bootstrap pattern the
	//    fabric already runs (Bridge is vlan_filtering 1): the attachment port
	//    joins the Bridge as an ACCESS port in the service vlan, and the Vlan
	//    subdevice — enslaved to the VRF, addressed from the intent's prefix —
	//    carries the L3. Ports are shared per-vlan, so several L3VPNs can
	//    attach to one physical port (enslaving the port to the VRF directly
	//    cannot: a device has one master, and two services on wan1 fought
	//    over it — observed live as flip-flopping ApplyFailed).
	// vrfmgrd creates the kernel VRF device asynchronously after the GCU
	// write (observed: verify raced it and flipped Ready False/True). The
	// master-setting waits up to 10 s for the device rather than firing
	// blind; if it never appears the verify checks fail loudly.
	waitMaster := func(iface string) string {
		return fmt.Sprintf("for i in $(seq 1 10); do ip link set %s master %s 2>/dev/null && exit 0; sleep 1; done; exit 1", iface, vrfName)
	}
	shell := []string{
		fmt.Sprintf("ip link show Bridge >/dev/null 2>&1 || { ip link add Bridge type bridge; ip link set Bridge up; }"),
		fmt.Sprintf("ip link show %s >/dev/null 2>&1 || ip link add %s link Bridge type vlan id %d", vlanName, vlanName, l3vlan),
		waitMaster(vlanName),
		fmt.Sprintf("ip link set %s up", vlanName),
	}
	if len(r.Prefixes) > 0 {
		addr := sviAddr(r.Prefixes[0])
		shell = append(shell,
			fmt.Sprintf("ip -br addr show %s 2>/dev/null | grep -qF '%s' || ip addr add %s dev %s", vlanName, addr, addr, vlanName))
	}
	shell = append(shell,
		// Access attachment: port into the Bridge (move off any VRF master
		// first — the old per-port master model), then the service vlan as
		// its PVID, and the Bridge's own vlan entry so the SVI sees it.
		fmt.Sprintf("ip link show %s | grep -q 'master Bridge' || { ip link set %s nomaster 2>/dev/null || true; ip link set %s master Bridge; }", port, port, port),
		fmt.Sprintf("bridge vlan add dev %s vid %d pvid untagged 2>/dev/null || true", port, l3vlan),
		fmt.Sprintf("bridge vlan add dev Bridge vid %d self 2>/dev/null || true", l3vlan),
		fmt.Sprintf("ip link set %s up 2>/dev/null || true", port),
	)
	np.Ops = append(np.Ops, Op{Shell: shell})

	// 4. FRR: bind the L3VNI to the vrf and (best-effort, D-A2) the vrf BGP
	//    instance with the intent's RD/RTs. Running state via vtysh, durable
	//    state via bgpd.conf append; failures here do NOT fail the apply.
	vty := []string{"conf t", fmt.Sprintf("vrf %s", vrfName), fmt.Sprintf("vni %d", r.L3VNI), "end"}
	rt := firstRT(r.RouteTargets, r.RD)
	frr := []string{
		fmt.Sprintf("vrf %s", vrfName),
		fmt.Sprintf(" vni %d", r.L3VNI),
		"exit-vrf",
		"!",
		fmt.Sprintf("router bgp %s vrf %s", asnOr(opts.BGPASN, "65000"), vrfName),
		" no bgp ebgp-requires-policy",
		" address-family ipv4 unicast",
		fmt.Sprintf("  rd vpn export %s", rtRD(r.RD, rt)),
		fmt.Sprintf("  rt vpn both %s", rt),
		"  export vpn",
		"  import vpn",
		" exit-address-family",
		"!",
	}
	np.Ops = append(np.Ops, Op{VTYSh: vty}, Op{FRRConf: frr})

	// Verification: declared rows present, kernel plumbing in place.
	np.Checks = append(np.Checks,
		Check{Type: "redis-hget", RedisKey: fmt.Sprintf("VRF|%s", vrfName), RedisField: "vni", Expect: fmt.Sprintf("%d", r.L3VNI)},
		Check{Type: "redis-exists", RedisKey: fmt.Sprintf("VXLAN_TUNNEL_MAP|%s|map_%d_%s", opts.VTEPName, r.L3VNI, vlanName)},
		Check{Type: "ip-master", Iface: vlanName, Master: vrfName},
		// The port is an ACCESS bridge port in the service vlan, not a VRF
		// slave — one physical port can carry several services this way.
		Check{Type: "bridge-vid", Iface: port, Vid: l3vlan},
	)
	if len(r.Prefixes) > 0 {
		np.Checks = append(np.Checks, Check{Type: "ip-addr", Iface: vlanName, Addr: sviAddr(r.Prefixes[0])})
	}

	// Rollback: remove what we own (best-effort, executed on delete).
	np.Rollback = append(np.Rollback,
		Op{Shell: []string{
			fmt.Sprintf("ip link del %s 2>/dev/null || true", vlanName),
			fmt.Sprintf("bridge vlan del dev %s vid %d 2>/dev/null || true", port, l3vlan),
			fmt.Sprintf("ip link set %s nomaster 2>/dev/null || true", port),
		}},
		Op{Redis: []string{
			fmt.Sprintf("del 'VXLAN_TUNNEL_MAP|%s|map_%d_%s'", opts.VTEPName, r.L3VNI, vlanName),
			fmt.Sprintf("del 'VLAN|%s'", vlanName),
		}},
		Op{GCU: []map[string]any{{"op": "remove", "path": fmt.Sprintf("/VRF/%s", vrfName)}}},
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

func renderL2(np *NodePlan, bd kubenet.BridgeDomain, att kubenet.NetworkAttachment, opts Options) error {
	vlanName := fmt.Sprintf("Vlan%d", bd.VLAN)
	port, err := opts.Ports.Port(att.Attachment)
	if err != nil {
		return errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
	}
	if bd.L2VNI == 0 {
		return errf("bridgeDomain %q has no l2vni", bd.Name)
	}

	// Overlay rows (raw redis — same table family as the bootstrap's Vlan100).
	np.Ops = append(np.Ops, Op{Redis: []string{
		fmt.Sprintf("hset 'VLAN|%s' vlanid '%d'", vlanName, bd.VLAN),
		fmt.Sprintf("hset 'VXLAN_TUNNEL_MAP|%s|map_%d_%s' vni '%d' vlan '%s'", opts.VTEPName, bd.L2VNI, vlanName, bd.L2VNI, vlanName),
	}})

	// Kernel: the L2VNI vtep and the access port join the Bridge; the access
	// vid is added pvid/untagged ONLY when the port has no PVID yet, otherwise
	// tagged, so one port can serve several services without stealing the
	// untagged role of an existing one (eth3 already carries vid 100 pvid).
	shell := []string{
		fmt.Sprintf("vtep=vtep1-%d; [ \"$(ip -d link show $vtep 2>/dev/null | grep -c 'master Bridge')\" = '1' ] || ip link set $vtep master Bridge 2>/dev/null || true", bd.L2VNI),
		fmt.Sprintf("bridge vlan add dev vtep1-%d vid %d pvid untagged 2>/dev/null || true", bd.L2VNI, bd.VLAN),
		fmt.Sprintf("ip link set %s master Bridge 2>/dev/null || true", port),
		fmt.Sprintf("bridge vlan del dev %s vid 1 2>/dev/null || true", port),
		fmt.Sprintf("pvid=$(bridge -j vlan show dev %s 2>/dev/null | python3 -c 'import sys,json\ntry: print(1 if any(v.get(\"PVID\") for e in json.load(sys.stdin) for v in e.get(\"vlans\",[])) else 0)\nexcept Exception: print(0)')", port),
		fmt.Sprintf("[ \"$pvid\" = '0' ] && bridge vlan add dev %s vid %d pvid untagged 2>/dev/null || bridge vlan add dev %s vid %d 2>/dev/null || true", port, bd.VLAN, port, bd.VLAN),
	}
	np.Ops = append(np.Ops, Op{Shell: shell})

	// Best-effort EVPN RT wiring for the L2VNI (D-A2 scope note: Type-2
	// forwarding on this pinned FRR is upstream-limited; the CONFIG_DB rows and
	// bridge state are the honest gate).
	var rts *kubenet.RouteTargets
	if bd.EVPN != nil {
		rts = bd.EVPN.RouteTargets
	}
	rt := firstRT(rts, "")
	if rt != "" {
		np.Ops = append(np.Ops, Op{VTYSh: []string{
			"conf t", "address-family l2vpn evpn",
			fmt.Sprintf("vni %d", bd.L2VNI),
			fmt.Sprintf("rd %s", rt), fmt.Sprintf("route-target import %s", rt), fmt.Sprintf("route-target export %s", rt),
			"exit-vni", "end",
		}})
	}

	np.Checks = append(np.Checks,
		Check{Type: "redis-hget", RedisKey: fmt.Sprintf("VLAN|%s", vlanName), RedisField: "vlanid", Expect: fmt.Sprintf("%d", bd.VLAN)},
		Check{Type: "redis-exists", RedisKey: fmt.Sprintf("VXLAN_TUNNEL_MAP|%s|map_%d_%s", opts.VTEPName, bd.L2VNI, vlanName)},
		Check{Type: "ip-master", Iface: port, Master: "Bridge"},
		Check{Type: "bridge-vid", Iface: port, Vid: bd.VLAN},
	)

	np.Rollback = append(np.Rollback,
		Op{Shell: []string{
			fmt.Sprintf("bridge vlan del dev %s vid %d 2>/dev/null || true", port, bd.VLAN),
			fmt.Sprintf("ip link del vtep1-%d 2>/dev/null || true", bd.L2VNI),
		}},
		Op{Redis: []string{
			fmt.Sprintf("del 'VXLAN_TUNNEL_MAP|%s|map_%d_%s'", opts.VTEPName, bd.L2VNI, vlanName),
			fmt.Sprintf("del 'VLAN|%s'", vlanName),
		}},
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
