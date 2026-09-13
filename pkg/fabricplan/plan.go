// SPDX-License-Identifier: Apache-2.0
// Package fabricplan renders Kubenet Network intent into per-node Nokia SR Linux
// device operations for the fabric-executor.
//
// This is the southbound translation the SDC path was supposed to provide. On
// SR Linux there is exactly ONE write primitive — a gNMI Set with JSON_IETF
// values against the node's native model — so the plan carries only that
// (see contracts/srlinux-render-contract.md and research D2/D5):
//
//   - every Op is one gNMI SetRequest (deletes first, then updates); SR Linux
//     commits a request atomically, so a half-applied op is not a state this
//     renderer has to reason about;
//   - every NodePlan carries its own verification Checks (gNMI Get assertions)
//     and its own Rollback ops, so apply, verify and rollback always agree on
//     the derived device names;
//   - attachment port naming is resolved by the caller through the site port
//     map (FABRIC_PORT_MAP): the spec's logical names (wan1, ethernet1) are not
//     SR Linux interface names (ethernet-1/4, ethernet-1/3).
//
// L3VNI-to-subinterface-tag derivation: the ip-vrf attachment is a
// single-tagged routed subinterface, and its tag is derived from the router's
// L3VNI through L3VLANForVNI into the reserved 4001-4094 band — a band the kuid
// fabric-vlan index can never allocate (maxID 4000), so a collision with an
// allocated L2 VLAN is impossible by construction. The derivation is kept from
// the SONiC target unchanged: it is what makes the allocator's L3VNI cap
// (14094) meaningful, and services already numbered by it keep their tags.
package fabricplan

import (
	"fmt"
	"net/netip"
	"sort"
	"strings"

	"github.com/mairp/agentic-netops/pkg/kubenet"
	"github.com/mairp/agentic-netops/pkg/migration"
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

// Op is a single device operation: one gNMI Set against the node.
type Op struct {
	GNMI *GNMISet `json:"gnmi,omitempty"`
}

// GNMISet is the body of one gNMI SetRequest. Deletes are applied before
// updates, which is what gNMI itself mandates within a request.
type GNMISet struct {
	Updates []GNMIUpdate `json:"updates,omitempty"`
	Deletes []string     `json:"deletes,omitempty"`
}

// GNMIUpdate is one JSON_IETF value at one SR Linux native path.
type GNMIUpdate struct {
	Path  string `json:"path"`
	Value any    `json:"value"`
}

// Check verifies one piece of applied state on the node over gNMI Get.
//
// Type is one of:
//
//	gnmi-equals   — the leaf value equals Expect (JSON scalars stringified)
//	gnmi-contains — the compact JSON body contains Expect as a substring
//	gnmi-exists   — the Get returns at least one non-null value
//	gnmi-list-min — the value is a list of at least MinCount entries
//	gnmi-absent   — the Get returns no value (NotFound is absence, not an error)
type Check struct {
	Type     string `json:"type"`
	Path     string `json:"path"`
	Expect   string `json:"expect,omitempty"`
	MinCount int    `json:"minCount,omitempty"`
}

// Error is a rendering failure that maps to a SchemaMismatch-style condition.
type Error struct{ Msg string }

func (e *Error) Error() string { return e.Msg }

func errf(format string, args ...any) error {
	return &Error{Msg: fmt.Sprintf(format, args...)}
}

// PortMapper resolves the spec's logical attachment names to SR Linux interfaces.
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
	// BGPASN is retained from the SONiC target for call-site compatibility. SR
	// Linux carries RD/RT per network-instance and takes the overlay ASN from
	// the node's own startup configuration, so the renderer never needs it.
	BGPASN string
	// VXLANTunnel is the per-leaf VXLAN tunnel-interface name (bootstrap
	// default vxlan1); every vxlan-interface this renderer creates lives under
	// it as vxlan1.<vni>.
	VXLANTunnel string
	// SystemIPv4 is unused: SR Linux sources VXLAN traffic from the system0
	// address through "use-system-ipv4-address", so the renderer never has to
	// know the node's loopback. Kept so a site that must pin it explicitly has
	// a declared place to do so.
	SystemIPv4 string
}

// fabricMTU is the jumbo MTU the lab links carry (FR-002). Rendering it on the
// attachment port keeps a service's frames from being the one thing on the
// fabric that cannot cross it.
const fabricMTU int64 = 9216

// irbInterface is the single IRB interface every symmetric-IRB service hangs
// its per-bridge-domain gateway subinterface off.
const irbInterface = "irb0"

// aclDefaultSequence is the sequence-id of the rendered default-action entry.
// It is the last id SR Linux accepts, so the declared rules (whose sequence-id
// is the intent's own priority) are always evaluated first.
const aclDefaultSequence int64 = 65535

// ForNetwork renders the complete plan. L3VPN (routers+attachments with vrf)
// and L2VPN (bridgeDomains+attachments with vlan) may coexist; nodes with no
// actionable attachment are skipped.
func ForNetwork(net *kubenet.Network, opts Options) (*Plan, error) {
	if len(opts.Ports) == 0 {
		return nil, errf("site port map is empty")
	}
	if opts.VXLANTunnel == "" {
		opts.VXLANTunnel = "vxlan1"
	}
	plan := &Plan{Nodes: map[string]*NodePlan{}}

	routers := map[string]kubenet.NetworkRouter{}
	for _, r := range net.Routers() {
		if r.Name == "" {
			return nil, errf("router with empty name")
		}
		routers[r.Name] = r
	}
	// L3VLANForVNI folds a 10001-wide VNI range into a 94-wide tag band, so
	// two l3vnis exactly l3VLANBandSize apart derive the same tag. Sharing it
	// would put two VRFs on one attachment subinterface — a silent tenant
	// merge. Refuse it here, in deterministic name order so the error is
	// reproducible.
	l3vlanOwner := map[int64]string{}
	routerNames := make([]string, 0, len(routers))
	for name := range routers {
		routerNames = append(routerNames, name)
	}
	sort.Strings(routerNames)
	for _, name := range routerNames {
		r := routers[name]
		if r.L3VNI == 0 {
			continue
		}
		vlan, err := L3VLANForVNI(r.L3VNI)
		if err != nil {
			return nil, err
		}
		if prev, ok := l3vlanOwner[vlan]; ok {
			return nil, errf("routers %q (l3vni %d) and %q (l3vni %d) both derive L3VLAN %d; l3vnis that differ by a multiple of %d collide in the reserved band — renumber one",
				prev, routers[prev].L3VNI, name, r.L3VNI, vlan, l3VLANBandSize)
		}
		l3vlanOwner[vlan] = name
	}
	bds := map[int64]kubenet.BridgeDomain{}
	for _, bd := range net.BridgeDomains() {
		if bd.VLAN == 0 {
			continue
		}
		// 4001-4094 is the derived-tag band (see the package comment). A
		// service VLAN there would collide with some L3VNI's own subinterface
		// tag, so it is rejected as an intent-shape error rather than silently
		// sharing.
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

	// Deterministic order for reproducible plans.
	atts := net.Attachments()
	sort.Slice(atts, func(i, j int) bool {
		if atts[i].Node != atts[j].Node {
			return atts[i].Node < atts[j].Node
		}
		return atts[i].Attachment < atts[j].Attachment
	})

	// bound tracks, per node and per resolved port, every subinterface index
	// this Network renders there. An ACL binds on exactly those subinterfaces:
	// on SR Linux the filter attaches to a subinterface, not to a port, so
	// "the ports this service uses" is not a precise enough answer.
	bound := map[string]map[string][]int64{}
	record := func(node, port string, idx int64) {
		byPort, ok := bound[node]
		if !ok {
			byPort = map[string][]int64{}
			bound[node] = byPort
		}
		byPort[port] = append(byPort[port], idx)
	}

	als := net.AccessLists()
	for _, att := range atts {
		np := plan.node(att.Node)
		switch {
		case att.VRF != "":
			r, ok := routers[att.VRF]
			if !ok {
				return nil, errf("attachment %s@%s references unknown router %q", att.Attachment, att.Node, att.VRF)
			}
			port, idx, err := renderL3(np, r, att, opts)
			if err != nil {
				return nil, err
			}
			record(att.Node, port, idx)
		case att.VLAN != 0:
			if bd, ok := bds[att.VLAN]; ok {
				if bd.IRB == nil {
					port, err := renderL2(np, bd, att, opts)
					if err != nil {
						return nil, err
					}
					record(att.Node, port, bd.VLAN)
					break
				}
				// Symmetric IRB: the bridge domain is the L2 half and its IRB
				// subinterface is the tenant gateway inside the router named by
				// irb.vrf. Without the router the routed half cannot be
				// rendered, and rendering only the L2 half would silently hand
				// back a VPLS.
				r, ok := routers[bd.IRB.VRF]
				if !ok {
					return nil, errf("bridgeDomain %q declares irb.vrf %q with no matching router", bd.Name, bd.IRB.VRF)
				}
				port, err := renderIRB(np, bd, r, att, opts)
				if err != nil {
					return nil, err
				}
				record(att.Node, port, bd.VLAN)
				break
			}
			// No bridgeDomain on this vlan — see if this is a local VLAN construct.
			if v, ok := vls[att.VLAN]; ok {
				port, err := renderVLAN(np, v, att, opts)
				if err != nil {
					return nil, err
				}
				record(att.Node, port, v.VLAN)
				break
			}
			return nil, errf("attachment %s@%s references vlan %d with no bridgeDomain or local VLAN (this network declares %s)",
				att.Attachment, att.Node, att.VLAN, declaredVLANs(bds, vls))
		default:
			// ACL-only attachment: allowed when the Network declares accessLists.
			// Rendering of ACLs happens separately; an ACL-only Network that produces
			// no node plans is still an error (checked after the loop).
			if len(als) > 0 {
				port, err := opts.Ports.Port(att.Attachment)
				if err != nil {
					return nil, errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
				}
				// Index 0 is the acl-only binding point (see renderACL).
				record(att.Node, port, 0)
				continue
			}
			return nil, errf("attachment %s@%s has neither vrf nor vlan", att.Attachment, att.Node)
		}
	}

	// Render ACLs onto nodes with attachments, bound to that node's own
	// subinterfaces only.
	if len(als) > 0 {
		nodes := make([]string, 0, len(bound))
		for node := range bound {
			nodes = append(nodes, node)
		}
		sort.Strings(nodes)
		for _, al := range als {
			for _, node := range nodes {
				np := plan.node(node)
				if err := renderACL(np, al, bound[node], net.ObjectMeta.Name, net.ObjectMeta.Namespace); err != nil {
					return nil, err
				}
			}
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

// l3VLANBandSize is the width of that reserved band (4001..4094 inclusive).
// The VNI space is far wider, so the derivation folds into it (see
// L3VLANForVNI) and ForNetwork refuses a fold collision rather than letting
// two VRFs share one subinterface tag.
const l3VLANBandSize int64 = 94

// evpnVNIMin/evpnVNIMax bound the kuid evpn-vni index, per the package comment.
const (
	evpnVNIMin int64 = 10000
	evpnVNIMax int64 = 20000
)

// L3VLANForVNI maps an L3VNI (kuid evpn-vni range) into the reserved 4001-4094
// band used as the ip-vrf attachment subinterface tag. See the package comment
// for why this band cannot collide with an allocated L2 VLAN.
//
// The mapping folds: the VNI range is 10001 wide and the band only 94, so a
// straight offset walked straight out of the 12-bit tag space — l3vni 10250
// derived tag 4250, which is not a valid single-tagged vlan-id. The fold is
// offset by one so that the first VNI past evpnVNIMin lands on the first tag in
// the band; that reproduces exactly what the straight offset produced for every
// VNI whose result happened to stay in range (l3vni 10007 still derives 4007),
// so services already programmed on the fabric are never renumbered.
func L3VLANForVNI(vni int64) (int64, error) {
	if vni < evpnVNIMin || vni > evpnVNIMax {
		return 0, errf("l3vni %d outside kuid evpn-vni range %d-%d; cannot derive an L3VLAN", vni, evpnVNIMin, evpnVNIMax)
	}
	slot := ((vni-evpnVNIMin-1)%l3VLANBandSize + l3VLANBandSize) % l3VLANBandSize
	return l3VLANBase + 1 + slot, nil
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

// --- path helpers ------------------------------------------------------------
//
// Every path this renderer emits is SR Linux native with the module prefix
// omitted, which is what the node's gNMI server and gnmic both accept. Keys
// containing "/" (ethernet-1/3) live inside the brackets and are parsed there
// by the executor's path parser, so they never need escaping here.

func ifacePath(port string) string { return fmt.Sprintf("/interface[name=%s]", port) }

func subifPath(port string, idx int64) string {
	return fmt.Sprintf("/interface[name=%s]/subinterface[index=%d]", port, idx)
}

func niPath(name string) string { return fmt.Sprintf("/network-instance[name=%s]", name) }

func vxlanIfPath(tunnel string, vni int64) string {
	return fmt.Sprintf("/tunnel-interface[name=%s]/vxlan-interface[index=%d]", tunnel, vni)
}

func aclFilterPath(name, family string) string {
	return fmt.Sprintf("/acl/acl-filter[name=%s,type=%s]", name, family)
}

// subifName is how a subinterface is referenced from a network-instance.
func subifName(port string, idx int64) string { return fmt.Sprintf("%s.%d", port, idx) }

// vxlanIfName is how a vxlan-interface is referenced from a network-instance.
func vxlanIfName(tunnel string, vni int64) string { return fmt.Sprintf("%s.%d", tunnel, vni) }

// --- value builders ----------------------------------------------------------

// portValue enables the physical attachment port for tagged service traffic.
// It is idempotent: re-applying it on a converged port is a no-op commit.
func portValue() map[string]any {
	return map[string]any{"admin-state": "enable", "vlan-tagging": true, "mtu": fabricMTU}
}

// bridgedSubifValue is an L2 attachment: single-tagged with its own vlan id,
// which is what keeps two services on one physical port apart (the "PVID
// stealing" class of defect the SONiC target had cannot exist here).
func bridgedSubifValue(idx int64) map[string]any {
	return map[string]any{
		"type":        "bridged",
		"admin-state": "enable",
		"vlan":        map[string]any{"encap": map[string]any{"single-tagged": map[string]any{"vlan-id": idx}}},
	}
}

// routedSubifValue is an L3 attachment: single-tagged, carrying the first host
// address of each declared address family.
func routedSubifValue(idx int64, v4, v6 string) map[string]any {
	val := map[string]any{
		"type":        "routed",
		"admin-state": "enable",
		"vlan":        map[string]any{"encap": map[string]any{"single-tagged": map[string]any{"vlan-id": idx}}},
	}
	if v4 != "" {
		val["ipv4"] = map[string]any{"admin-state": "enable", "address": []any{map[string]any{"ip-prefix": v4}}}
	}
	if v6 != "" {
		val["ipv6"] = map[string]any{"admin-state": "enable", "address": []any{map[string]any{"ip-prefix": v6}}}
	}
	return val
}

// vxlanIfValue is one VNI's tunnel endpoint. "use-system-ipv4-address" is what
// makes the VTEP the node's own system0 address without the renderer having to
// know it (see Options.SystemIPv4).
func vxlanIfValue(kind string, vni int64) map[string]any {
	return map[string]any{
		"type":    kind, // bridged for a mac-vrf, routed for an ip-vrf
		"ingress": map[string]any{"vni": vni},
		"egress":  map[string]any{"source-ip": "use-system-ipv4-address"},
	}
}

// evpnProtocols is the bgp-evpn + bgp-vpn pair every overlay network-instance
// carries. evi == vni (both inside 1..65535 for the pinned kuid pools), and the
// route-distinguisher object is omitted when the intent declares no RD, which
// makes SR Linux derive <system-ip>:<evi> for it.
func evpnProtocols(tunnel string, vni int64, rd, rt string) map[string]any {
	bgpVPN := map[string]any{"id": int64(1)}
	if rd != "" {
		bgpVPN["route-distinguisher"] = map[string]any{"rd": rd}
	}
	if rt != "" {
		bgpVPN["route-target"] = map[string]any{"export-rt": rt, "import-rt": rt}
	}
	return map[string]any{
		"bgp-evpn": map[string]any{"bgp-instance": []any{map[string]any{
			"id":              int64(1),
			"admin-state":     "enable",
			"vxlan-interface": vxlanIfName(tunnel, vni),
			"evi":             vni,
			"ecmp":            int64(2),
		}}},
		"bgp-vpn": map[string]any{"bgp-instance": []any{bgpVPN}},
	}
}

// --- derived names -----------------------------------------------------------

// DeviceVRFName derives the on-device network-instance name from the intent's
// router name: strip a leading "vrf-" (case-insensitive), sanitize, cap the
// remainder at 10, prefix "Vrf-".
//
// SR Linux network-instance names accept up to 255 characters, so the 14-char
// cap is no longer a schema limit — it is a stability guarantee. Services that
// were numbered against the SONiC target keep the exact device name they had,
// and apply, verify and rollback keep agreeing on one derivation.
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
	if len(rest) > 10 {
		rest = rest[:10]
	}
	return "Vrf-" + rest, nil
}

// DeviceBridgeNIName derives the mac-vrf network-instance name from the bridge
// domain's own name, falling back to macvrf-<vlan> when the intent's name is
// not a usable SR Linux identifier. Deterministic, so the L2 half's apply,
// verify and rollback name the same object.
func DeviceBridgeNIName(bdName string, vlan int64) string {
	var b strings.Builder
	for _, r := range bdName {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_', r == '.':
			b.WriteRune(r)
		}
	}
	s := b.String()
	if s == "" || !isLetter(rune(s[0])) {
		return fmt.Sprintf("macvrf-%d", vlan)
	}
	if len(s) > 255 {
		s = s[:255]
	}
	return s
}

func isLetter(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}

// DeviceACLTableName delegates to migration.DeviceACLTableName for determinism across apply/verify/rollback.
func DeviceACLTableName(serviceID, stage string) (string, error) {
	return migration.DeviceACLTableName(serviceID, stage)
}

// --- vlan (local) ------------------------------------------------------------

// renderVLAN renders a local VLAN construct: a mac-vrf network-instance with no
// VNI, no vxlan-interface and no EVPN — a broadcast domain that never leaves
// the node. It returns the resolved port so the caller can bind ACLs on it.
func renderVLAN(np *NodePlan, v kubenet.NetworkVLAN, att kubenet.NetworkAttachment, opts Options) (string, error) {
	port, err := opts.Ports.Port(att.Attachment)
	if err != nil {
		return "", errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
	}
	ni := fmt.Sprintf("vlan-%d", v.VLAN)

	np.Ops = append(np.Ops,
		Op{GNMI: &GNMISet{Updates: []GNMIUpdate{
			{Path: ifacePath(port), Value: portValue()},
			{Path: subifPath(port, v.VLAN), Value: bridgedSubifValue(v.VLAN)},
		}}},
		Op{GNMI: &GNMISet{Updates: []GNMIUpdate{
			{Path: niPath(ni), Value: map[string]any{
				"type":        "mac-vrf",
				"admin-state": "enable",
				"interface":   []any{map[string]any{"name": subifName(port, v.VLAN)}},
			}},
		}}},
	)
	np.Checks = append(np.Checks,
		Check{Type: "gnmi-equals", Path: niPath(ni) + "/oper-state", Expect: "up"},
		Check{Type: "gnmi-equals", Path: subifPath(port, v.VLAN) + "/oper-state", Expect: "up"},
	)
	np.Rollback = append(np.Rollback,
		Op{GNMI: &GNMISet{Deletes: []string{niPath(ni)}}},
		Op{GNMI: &GNMISet{Deletes: []string{subifPath(port, v.VLAN)}}},
	)
	return port, nil
}

// --- mac-vrf -----------------------------------------------------------------

// l2RT is the bridge domain's route target, normalised, or "" when it declares none.
func l2RT(bd kubenet.BridgeDomain) string {
	var rts *kubenet.RouteTargets
	if bd.EVPN != nil {
		rts = bd.EVPN.RouteTargets
	}
	return normalizeRT(firstRT(rts))
}

// macVRFOps renders the L2 half of an overlay service: the tagged attachment
// subinterface, the L2VNI's vxlan-interface and the mac-vrf network-instance.
// extraInterfaces carries the IRB subinterface when this bridge domain has one.
func macVRFOps(bd kubenet.BridgeDomain, ni, port string, extraInterfaces []string, opts Options) []Op {
	ifaces := []any{map[string]any{"name": subifName(port, bd.VLAN)}}
	for _, extra := range extraInterfaces {
		ifaces = append(ifaces, map[string]any{"name": extra})
	}
	return []Op{
		{GNMI: &GNMISet{Updates: []GNMIUpdate{
			{Path: ifacePath(port), Value: portValue()},
			{Path: subifPath(port, bd.VLAN), Value: bridgedSubifValue(bd.VLAN)},
		}}},
		{GNMI: &GNMISet{Updates: []GNMIUpdate{
			{Path: vxlanIfPath(opts.VXLANTunnel, bd.L2VNI), Value: vxlanIfValue("bridged", bd.L2VNI)},
		}}},
		{GNMI: &GNMISet{Updates: []GNMIUpdate{
			{Path: niPath(ni), Value: map[string]any{
				"type":            "mac-vrf",
				"admin-state":     "enable",
				"interface":       ifaces,
				"vxlan-interface": []any{map[string]any{"name": vxlanIfName(opts.VXLANTunnel, bd.L2VNI)}},
				// The kubenet bridgeDomain schema declares no RD, so the
				// route-distinguisher object is omitted and SR Linux derives
				// <system-ip>:<evi> for it.
				"protocols": evpnProtocols(opts.VXLANTunnel, bd.L2VNI, "", l2RT(bd)),
			}},
		}}},
	}
}

// macVRFChecks proves the L2 half converged. The last check is the only one
// self-origination cannot fake: a multicast destination under this VNI's
// bridge-table is a remote VTEP the peer's IMET route brought in, so it is the
// signal that the overlay actually formed.
func macVRFChecks(bd kubenet.BridgeDomain, ni, port string, opts Options) []Check {
	vx := vxlanIfPath(opts.VXLANTunnel, bd.L2VNI)
	return []Check{
		{Type: "gnmi-equals", Path: niPath(ni) + "/oper-state", Expect: "up"},
		{Type: "gnmi-equals", Path: subifPath(port, bd.VLAN) + "/oper-state", Expect: "up"},
		{Type: "gnmi-equals", Path: niPath(ni) + "/protocols/bgp-evpn/bgp-instance[id=1]/oper-state", Expect: "up"},
		{Type: "gnmi-equals", Path: vx + "/oper-state", Expect: "up"},
		{Type: "gnmi-list-min", Path: vx + "/bridge-table/multicast-destinations/destination", MinCount: 1},
	}
}

// macVRFRollback withdraws exactly what the L2 half created, in reverse order:
// the network-instance first (it references the other two), then the VNI's
// tunnel endpoint, then the attachment subinterface. The physical port is never
// deleted — this service did not create it.
func macVRFRollback(bd kubenet.BridgeDomain, ni, port string, opts Options) []Op {
	return []Op{
		{GNMI: &GNMISet{Deletes: []string{niPath(ni)}}},
		{GNMI: &GNMISet{Deletes: []string{vxlanIfPath(opts.VXLANTunnel, bd.L2VNI)}}},
		{GNMI: &GNMISet{Deletes: []string{subifPath(port, bd.VLAN)}}},
	}
}

func renderL2(np *NodePlan, bd kubenet.BridgeDomain, att kubenet.NetworkAttachment, opts Options) (string, error) {
	if bd.L2VNI == 0 {
		return "", errf("bridgeDomain %q has no l2vni", bd.Name)
	}
	port, err := opts.Ports.Port(att.Attachment)
	if err != nil {
		return "", errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
	}
	ni := DeviceBridgeNIName(bd.Name, bd.VLAN)

	np.Ops = append(np.Ops, macVRFOps(bd, ni, port, nil, opts)...)
	np.Checks = append(np.Checks, macVRFChecks(bd, ni, port, opts)...)
	np.Rollback = append(np.Rollback, macVRFRollback(bd, ni, port, opts)...)
	return port, nil
}

// --- ip-vrf ------------------------------------------------------------------

// l3Context is the per-router device naming and identifiers that BOTH routed
// paths need — the L3VPN attachment and the routed half of a symmetric IRB.
// Deriving it in one place is what keeps apply, verify and rollback agreeing on
// every name (the derived VRF name, the derived subinterface tag, the RD/RT).
type l3Context struct {
	VRFName string // on-device network-instance (DeviceVRFName)
	L3VNI   int64
	L3VLAN  int64  // derived single-tag for the attachment subinterface
	RD      string // omitted from the plan when empty (SR Linux derives it)
	RT      string // normalised to target:<asn>:<n>
}

func l3ContextFor(r kubenet.NetworkRouter) (l3Context, error) {
	if r.L3VNI == 0 {
		return l3Context{}, errf("router %q has no l3vni", r.Name)
	}
	vrfName, err := DeviceVRFName(r.Name)
	if err != nil {
		return l3Context{}, errf("router %q: %v", r.Name, err)
	}
	l3vlan, err := L3VLANForVNI(r.L3VNI)
	if err != nil {
		return l3Context{}, err
	}
	return l3Context{
		VRFName: vrfName,
		L3VNI:   r.L3VNI,
		L3VLAN:  l3vlan,
		RD:      r.RD,
		RT:      normalizeRT(firstRT(r.RouteTargets)),
	}, nil
}

// ipVRFOp renders the ip-vrf network-instance itself. interfaces are the
// subinterface names that live in it (the wan attachment for an L3VPN, the IRB
// subinterface for a symmetric IRB).
func (c l3Context) ipVRFOp(interfaces []string, opts Options) Op {
	ifaces := make([]any, 0, len(interfaces))
	for _, name := range interfaces {
		ifaces = append(ifaces, map[string]any{"name": name})
	}
	return Op{GNMI: &GNMISet{Updates: []GNMIUpdate{
		{Path: niPath(c.VRFName), Value: map[string]any{
			"type":            "ip-vrf",
			"admin-state":     "enable",
			"interface":       ifaces,
			"vxlan-interface": []any{map[string]any{"name": vxlanIfName(opts.VXLANTunnel, c.L3VNI)}},
			"protocols":       evpnProtocols(opts.VXLANTunnel, c.L3VNI, c.RD, c.RT),
		}},
	}}}
}

// vxlanRoutedOp renders the L3VNI's own tunnel endpoint (symmetric IRB transit).
func (c l3Context) vxlanRoutedOp(opts Options) Op {
	return Op{GNMI: &GNMISet{Updates: []GNMIUpdate{
		{Path: vxlanIfPath(opts.VXLANTunnel, c.L3VNI), Value: vxlanIfValue("routed", c.L3VNI)},
	}}}
}

func (c l3Context) baseChecks(opts Options) []Check {
	return []Check{
		{Type: "gnmi-equals", Path: niPath(c.VRFName) + "/oper-state", Expect: "up"},
		{Type: "gnmi-equals", Path: niPath(c.VRFName) + "/protocols/bgp-evpn/bgp-instance[id=1]/oper-state", Expect: "up"},
		{Type: "gnmi-equals", Path: vxlanIfPath(opts.VXLANTunnel, c.L3VNI) + "/oper-state", Expect: "up"},
	}
}

// type5Path is where SR Linux exposes the EVPN routes this node advertises.
// Asserting the service's own prefix there is what proves the ip-vrf is
// ORIGINATING a Type-5, not merely configured.
//
// Verify live: the exact list node under rib-out-post on 26.7 (research D5).
const type5Path = "/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-out-post/ip-prefix-routes"

// type5Checks asserts the service's own prefixes are locally originated as
// EVPN Type-5 routes. Prefixes are masked first: host bits in operator input
// would otherwise make verification look for a route the fabric necessarily
// normalises to the network address.
func type5Checks(prefixes []string) ([]Check, error) {
	var checks []Check
	for _, prefix := range prefixes {
		if prefix == "" {
			continue
		}
		p, err := netip.ParsePrefix(prefix)
		if err != nil {
			return nil, errf("invalid prefix %q: %v", prefix, err)
		}
		checks = append(checks, Check{Type: "gnmi-contains", Path: type5Path, Expect: p.Masked().String()})
	}
	return checks, nil
}

func renderL3(np *NodePlan, r kubenet.NetworkRouter, att kubenet.NetworkAttachment, opts Options) (string, int64, error) {
	c, err := l3ContextFor(r)
	if err != nil {
		return "", 0, err
	}
	port, err := opts.Ports.Port(att.Attachment)
	if err != nil {
		return "", 0, errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
	}
	v4, v6, err := firstHosts(r.Prefixes)
	if err != nil {
		return "", 0, errf("router %q: %v", r.Name, err)
	}

	np.Ops = append(np.Ops,
		Op{GNMI: &GNMISet{Updates: []GNMIUpdate{
			{Path: ifacePath(port), Value: portValue()},
			{Path: subifPath(port, c.L3VLAN), Value: routedSubifValue(c.L3VLAN, v4, v6)},
		}}},
		c.vxlanRoutedOp(opts),
		c.ipVRFOp([]string{subifName(port, c.L3VLAN)}, opts),
	)

	np.Checks = append(np.Checks, c.baseChecks(opts)...)
	np.Checks = append(np.Checks, Check{Type: "gnmi-equals", Path: subifPath(port, c.L3VLAN) + "/oper-state", Expect: "up"})
	if len(r.Prefixes) > 0 {
		type5, err := type5Checks(r.Prefixes[:1])
		if err != nil {
			return "", 0, errf("router %q: %v", r.Name, err)
		}
		np.Checks = append(np.Checks, type5...)
	}

	np.Rollback = append(np.Rollback,
		Op{GNMI: &GNMISet{Deletes: []string{niPath(c.VRFName)}}},
		Op{GNMI: &GNMISet{Deletes: []string{vxlanIfPath(opts.VXLANTunnel, c.L3VNI)}}},
		Op{GNMI: &GNMISet{Deletes: []string{subifPath(port, c.L3VLAN)}}},
	)
	return port, c.L3VLAN, nil
}

// --- IRB ---------------------------------------------------------------------

// renderIRB renders a symmetric IRB service: the bridge domain's L2 half
// exactly as renderL2 builds it, plus the routed half — the domain's IRB
// subinterface is the tenant anycast gateway and lives inside the ip-vrf named
// by irb.vrf, which carries its own L3VNI. Rendering only the L2 half silently
// hands the operator a VPLS.
func renderIRB(np *NodePlan, bd kubenet.BridgeDomain, r kubenet.NetworkRouter, att kubenet.NetworkAttachment, opts Options) (string, error) {
	if bd.L2VNI == 0 {
		return "", errf("bridgeDomain %q has no l2vni", bd.Name)
	}
	c, err := l3ContextFor(r)
	if err != nil {
		return "", err
	}
	port, err := opts.Ports.Port(att.Attachment)
	if err != nil {
		return "", errf("attachment %s@%s: %v", att.Attachment, att.Node, err)
	}
	gateways := []string{bd.IRB.GatewayV4, bd.IRB.GatewayV6}
	gw4, gw6, err := firstHosts(gateways)
	if err != nil {
		return "", errf("bridgeDomain %q: %v", bd.Name, err)
	}
	ni := DeviceBridgeNIName(bd.Name, bd.VLAN)
	irbSubif := subifName(irbInterface, bd.VLAN)

	// 1. The L2 half, with the gateway subinterface joined to the mac-vrf.
	np.Ops = append(np.Ops, macVRFOps(bd, ni, port, []string{irbSubif}, opts)...)
	// 2. The anycast gateway itself. Every leaf carries the same address, which
	//    is what makes the gateway follow the workload instead of trombone.
	np.Ops = append(np.Ops, Op{GNMI: &GNMISet{Updates: []GNMIUpdate{
		{Path: ifacePath(irbInterface), Value: map[string]any{"admin-state": "enable"}},
		{Path: subifPath(irbInterface, bd.VLAN), Value: irbSubifValue(gw4, gw6)},
	}}})
	// 3. The routed half: the L3VNI's tunnel endpoint and the ip-vrf that owns
	//    the gateway. No wan subinterface — an IRB's routed attachment IS the
	//    gateway.
	np.Ops = append(np.Ops, c.vxlanRoutedOp(opts), c.ipVRFOp([]string{irbSubif}, opts))

	np.Checks = append(np.Checks, macVRFChecks(bd, ni, port, opts)...)
	np.Checks = append(np.Checks, c.baseChecks(opts)...)
	np.Checks = append(np.Checks, Check{Type: "gnmi-equals", Path: subifPath(irbInterface, bd.VLAN) + "/oper-state", Expect: "up"})
	type5, err := type5Checks(gateways)
	if err != nil {
		return "", errf("bridgeDomain %q: %v", bd.Name, err)
	}
	np.Checks = append(np.Checks, type5...)

	np.Rollback = append(np.Rollback,
		Op{GNMI: &GNMISet{Deletes: []string{niPath(c.VRFName)}}},
		Op{GNMI: &GNMISet{Deletes: []string{vxlanIfPath(opts.VXLANTunnel, c.L3VNI)}}},
		Op{GNMI: &GNMISet{Deletes: []string{subifPath(irbInterface, bd.VLAN)}}},
	)
	np.Rollback = append(np.Rollback, macVRFRollback(bd, ni, port, opts)...)
	return port, nil
}

// irbSubifValue is the anycast gateway subinterface. anycast-gw on the address
// plus the interface-level anycast-gw container is what lets every leaf answer
// for the same gateway address.
func irbSubifValue(gw4, gw6 string) map[string]any {
	val := map[string]any{"admin-state": "enable", "anycast-gw": map[string]any{}}
	if gw4 != "" {
		val["ipv4"] = map[string]any{
			"admin-state": "enable",
			"address":     []any{map[string]any{"ip-prefix": gw4, "anycast-gw": true}},
		}
	}
	if gw6 != "" {
		val["ipv6"] = map[string]any{
			"admin-state": "enable",
			"address":     []any{map[string]any{"ip-prefix": gw6, "anycast-gw": true}},
		}
	}
	return val
}

// --- acl ---------------------------------------------------------------------

// renderACL renders an acl-filter and binds it on every subinterface this
// Network renders on this node. subifs maps the node's resolved ports to the
// subinterface indexes the service created there; an ACL-only Network has no
// service subinterface of its own and binds on index 0.
func renderACL(np *NodePlan, al kubenet.AccessList, subifs map[string][]int64, serviceID, tenant string) error {
	if len(subifs) == 0 {
		return nil // nothing to bind on this node
	}
	table, err := DeviceACLTableName(serviceID, al.Stage)
	if err != nil {
		return err
	}
	family := aclFamily(al.Type)
	direction := "input"
	if strings.EqualFold(al.Stage, "egress") {
		direction = "output"
	}
	filter := aclFilterPath(table, family)

	entries := make([]any, 0, len(al.Rules)+1)
	for _, r := range al.Rules {
		entry, err := aclEntry(r, family)
		if err != nil {
			return errf("accessList %q rule %q: %v", al.Name, r.Name, err)
		}
		entries = append(entries, entry)
	}
	if al.DefaultAction != "" {
		// The default action is the LAST entry: SR Linux evaluates acl-filter
		// entries in sequence-id order, so a default at a low id would shadow
		// every declared rule.
		entries = append(entries, map[string]any{
			"sequence-id": aclDefaultSequence,
			"action":      aclAction(al.DefaultAction),
		})
	}
	np.Ops = append(np.Ops, Op{GNMI: &GNMISet{Updates: []GNMIUpdate{
		{Path: filter, Value: map[string]any{
			"description": fmt.Sprintf("%s/%s", tenant, serviceID),
			"entry":       entries,
		}},
	}}})

	// Bindings, deterministic in port then index order.
	ports := make([]string, 0, len(subifs))
	for p := range subifs {
		ports = append(ports, p)
	}
	sort.Strings(ports)
	binding := map[string]any{"acl-filter": []any{map[string]any{"name": table, "type": family}}}
	var bindPaths []string
	for _, port := range ports {
		for _, idx := range dedupInts(subifs[port]) {
			if idx == 0 {
				// ACL-only binding point. Index 0 is created as a routed
				// subinterface in the default network-instance when the node
				// does not already have one; when it does and it belongs to
				// another network-instance (the bootstrap client domain on
				// ethernet-1/3), the node refuses the change and the executor
				// reports its error verbatim. That is the documented limitation
				// of an ACL that names no service of its own — it mirrors the
				// port-level binding the SONiC target had.
				np.Ops = append(np.Ops, Op{GNMI: &GNMISet{Updates: []GNMIUpdate{
					{Path: ifacePath(port), Value: map[string]any{"admin-state": "enable"}},
					{Path: subifPath(port, 0), Value: map[string]any{"type": "routed", "admin-state": "enable"}},
					{Path: niPath("default"), Value: map[string]any{
						"interface": []any{map[string]any{"name": subifName(port, 0)}},
					}},
				}}})
			}
			path := subifPath(port, idx) + "/acl/" + direction
			bindPaths = append(bindPaths, path)
			np.Ops = append(np.Ops, Op{GNMI: &GNMISet{Updates: []GNMIUpdate{{Path: path, Value: binding}}}})
			np.Checks = append(np.Checks, Check{
				Type: "gnmi-exists",
				Path: fmt.Sprintf("%s/acl-filter[name=%s,type=%s]", path, table, family),
			})
		}
	}

	for _, r := range al.Rules {
		entryPath := fmt.Sprintf("%s/entry[sequence-id=%d]", filter, r.Priority)
		np.Checks = append(np.Checks,
			Check{Type: "gnmi-exists", Path: entryPath},
			// The applied side: statistics only exist once the entry is
			// programmed, so reading them is the difference between a filter
			// that is configured and one that is in the data path.
			// Verify live: the statistics container on 26.7.
			Check{Type: "gnmi-exists", Path: entryPath + "/statistics"},
		)
	}
	if al.DefaultAction != "" {
		np.Checks = append(np.Checks, Check{
			Type: "gnmi-exists",
			Path: fmt.Sprintf("%s/entry[sequence-id=%d]", filter, aclDefaultSequence),
		})
	}

	// Rollback: unbind first (the filter cannot be removed while referenced),
	// then remove the filter itself. Nothing else this Network did not create.
	for i := len(bindPaths) - 1; i >= 0; i-- {
		np.Rollback = append(np.Rollback, Op{GNMI: &GNMISet{Deletes: []string{
			fmt.Sprintf("%s/acl-filter[name=%s,type=%s]", bindPaths[i], table, family),
		}}})
	}
	np.Rollback = append(np.Rollback, Op{GNMI: &GNMISet{Deletes: []string{filter}}})
	return nil
}

// aclFamily maps the intent's access-list type onto SR Linux's acl-filter type.
func aclFamily(t string) string {
	if strings.EqualFold(t, "l3v6") {
		return "ipv6"
	}
	return "ipv4"
}

// aclAction maps the intent's action onto SR Linux's action container.
func aclAction(a string) map[string]any {
	switch strings.ToLower(a) {
	case "permit", "allow", "forward", "accept":
		return map[string]any{"accept": map[string]any{}}
	default:
		return map[string]any{"drop": map[string]any{}}
	}
}

// aclEntry renders one match/action row. The sequence-id is the intent's own
// priority, so the operator's ordering is the device's ordering.
func aclEntry(r kubenet.ACLRule, family string) (map[string]any, error) {
	match := map[string]any{}
	ip := map[string]any{}
	if proto := r.Protocol; proto != "" && !strings.EqualFold(proto, "any") {
		p, err := aclProtocol(proto, family)
		if err != nil {
			return nil, err
		}
		ip["protocol"] = p
	}
	if r.SourcePrefix != "" {
		ip["source-ip"] = map[string]any{"prefix": r.SourcePrefix}
	}
	if r.DestinationPrefix != "" {
		ip["destination-ip"] = map[string]any{"prefix": r.DestinationPrefix}
	}
	if len(ip) > 0 {
		match[family] = ip
	}
	transport := map[string]any{}
	if r.SourcePort != "" {
		v, err := aclPort(r.SourcePort)
		if err != nil {
			return nil, err
		}
		transport["source-port"] = v
	}
	if r.DestinationPort != "" {
		v, err := aclPort(r.DestinationPort)
		if err != nil {
			return nil, err
		}
		transport["destination-port"] = v
	}
	if len(transport) > 0 {
		match["transport"] = transport
	}
	entry := map[string]any{
		"sequence-id": r.Priority,
		"action":      aclAction(r.Action),
	}
	if r.Description != "" {
		entry["description"] = r.Description
	}
	if len(match) > 0 {
		entry["match"] = match
	}
	return entry, nil
}

// aclProtocol names the protocol the way SR Linux's acl model does. ICMPv6 is
// refused for parity with the original target: an ICMPv6 rule on an ipv4 filter
// is a silent no-match, and the intent tier has no way to express the ipv6
// filter it would need.
func aclProtocol(proto, family string) (any, error) {
	switch strings.ToLower(proto) {
	case "tcp":
		return "tcp", nil
	case "udp":
		return "udp", nil
	case "icmp":
		if family == "ipv6" {
			return nil, errf("protocol icmp is not matchable on an ipv6 filter; use an l3 (ipv4) access list")
		}
		return "icmp", nil
	case "icmpv6", "icmp6", "ipv6-icmp":
		return nil, errf("protocol %q is not supported on this fabric; use tcp, udp, icmp or a protocol number", proto)
	case "igmp":
		return "igmp", nil
	case "gre":
		return "gre", nil
	case "ospf":
		return "ospf", nil
	case "pim":
		return "pim", nil
	case "vrrp":
		return "vrrp", nil
	default:
		// A protocol number passes through: SR Linux accepts the numeric form
		// wherever the name is not one of its enumerated identities.
		n, err := parseUint(proto)
		if err != nil {
			return nil, errf("protocol %q is neither a known name nor a protocol number", proto)
		}
		return n, nil
	}
}

// aclPort renders a single port or an inclusive range ("8000-8100").
func aclPort(p string) (map[string]any, error) {
	if lo, hi, ok := strings.Cut(p, "-"); ok {
		start, err := parseUint(strings.TrimSpace(lo))
		if err != nil {
			return nil, errf("port range %q: %v", p, err)
		}
		end, err := parseUint(strings.TrimSpace(hi))
		if err != nil {
			return nil, errf("port range %q: %v", p, err)
		}
		return map[string]any{"range": map[string]any{"start": start, "end": end}}, nil
	}
	v, err := parseUint(strings.TrimSpace(p))
	if err != nil {
		return nil, errf("port %q: %v", p, err)
	}
	return map[string]any{"value": v}, nil
}

func parseUint(s string) (int64, error) {
	if s == "" {
		return 0, fmt.Errorf("empty number")
	}
	var n int64
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("%q is not a number", s)
		}
		n = n*10 + int64(r-'0')
		if n > 1<<31 {
			return 0, fmt.Errorf("%q is out of range", s)
		}
	}
	return n, nil
}

// --- small helpers -----------------------------------------------------------

// firstHosts returns the first usable host address of the first IPv4 and the
// first IPv6 prefix in the list. A prefix whose address is already a host
// address (an IRB gateway) is returned unchanged.
func firstHosts(prefixes []string) (string, string, error) {
	var v4, v6 string
	for _, p := range prefixes {
		if p == "" {
			continue
		}
		host, is6, err := firstHost(p)
		if err != nil {
			return "", "", err
		}
		if is6 {
			if v6 == "" {
				v6 = host
			}
			continue
		}
		if v4 == "" {
			v4 = host
		}
	}
	return v4, v6, nil
}

// firstHost derives the address the node carries on a service prefix: the first
// usable host (x.y.z.1/n), the same convention the bootstrap uses. On a prefix
// with no host space (/31, /32, /127, /128) the network address itself is the
// address.
func firstHost(prefix string) (string, bool, error) {
	p, err := netip.ParsePrefix(prefix)
	if err != nil {
		return "", false, errf("invalid prefix %q: %v", prefix, err)
	}
	addr := p.Masked().Addr()
	if p.Bits() < addr.BitLen()-1 {
		addr = addr.Next()
		if !addr.IsValid() {
			return "", false, errf("prefix %q has no usable host address", prefix)
		}
	}
	return fmt.Sprintf("%s/%d", addr, p.Bits()), p.Addr().Is6(), nil
}

// normalizeRT prefixes the allocator's bare "65000:18" with the "target:"
// SR Linux requires; an RT that already carries a type prefix is left alone.
func normalizeRT(rt string) string {
	if rt == "" || strings.HasPrefix(rt, "target:") {
		return rt
	}
	return "target:" + rt
}

func firstRT(rts *kubenet.RouteTargets) string {
	if rts != nil {
		if len(rts.Export) > 0 {
			return rts.Export[0]
		}
		if len(rts.Import) > 0 {
			return rts.Import[0]
		}
	}
	return ""
}

func dedupInts(in []int64) []int64 {
	seen := map[int64]bool{}
	out := make([]int64, 0, len(in))
	for _, v := range in {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
