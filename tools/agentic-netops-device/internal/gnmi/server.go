package gnmi

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	gnmiPb "github.com/openconfig/gnmi/proto/gnmi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	"github.com/mairp/agentic-netops-device/internal/redisx"
)

// Config configures the gNMI server.
type Config struct {
	Addr         string // listen address (default 0.0.0.0:8080)
	RedisAddr    string // redis address (default 127.0.0.1:6379)
	CertDir      string // dir with ca.crt, gnmi.crt, gnmi.key ("" disables mTLS)
	User         string // expected username (default admin)
	Pass         string // expected password (default admin)
	ConfigDB     int    // CONFIG_DB id (default 4)
	StateDB      int    // STATE_DB id (default 6)
	ManagedPaths []string
}

// Server is the Agentic NetOps gNMI device server.
type Server struct {
	gnmiPb.UnimplementedGNMIServer
	cfg  Config
	mu   sync.Mutex
	cfgc *redisx.Client // CONFIG_DB connection
	stc  *redisx.Client // STATE_DB connection
}

// New builds a Server and connects to redis.
func New(cfg Config) (*Server, error) {
	if cfg.Addr == "" {
		cfg.Addr = "0.0.0.0:8080"
	}
	if cfg.RedisAddr == "" {
		cfg.RedisAddr = "127.0.0.1:6379"
	}
	if cfg.User == "" {
		cfg.User = "admin"
	}
	if cfg.Pass == "" {
		cfg.Pass = "admin"
	}
	if cfg.ConfigDB == 0 {
		cfg.ConfigDB = 4
	}
	if cfg.StateDB == 0 {
		cfg.StateDB = 6
	}
	cfgc, err := redisx.New(cfg.RedisAddr)
	if err != nil {
		return nil, fmt.Errorf("redis config db: %w", err)
	}
	if err := cfgc.Select(cfg.ConfigDB); err != nil {
		return nil, err
	}
	stc, err := redisx.New(cfg.RedisAddr)
	if err != nil {
		return nil, fmt.Errorf("redis state db: %w", err)
	}
	if err := stc.Select(cfg.StateDB); err != nil {
		return nil, err
	}
	return &Server{cfg: cfg, cfgc: cfgc, stc: stc}, nil
}

// ---------------------------------------------------------------------------
// Redis helpers
// ---------------------------------------------------------------------------

func (s *Server) cfgTableKeys(table string) []string {
	keys, _ := s.cfgc.TableKeys(table)
	return keys
}

func (s *Server) cfgHash(key string) map[string]string {
	h, _ := s.cfgc.HGetAll(key)
	return h
}

func (s *Server) stateHash(key string) map[string]string {
	h, _ := s.stc.HGetAll(key)
	return h
}

func (s *Server) stateTableKeys(table string) []string {
	keys, _ := s.stc.TableKeys(table)
	return keys
}

// ---------------------------------------------------------------------------
// gNMI: Capabilities
// ---------------------------------------------------------------------------

func (s *Server) Capabilities(ctx context.Context, req *gnmiPb.CapabilityRequest) (*gnmiPb.CapabilityResponse, error) {
	models := []string{
		"openconfig-interfaces@2023-06-01",
		"openconfig-network-instance@2023-06-01",
		"openconfig-bgp@2023-05-12",
		"openconfig-vlan@2023-05-12",
		"sonic-telemetry",
		"sonic-vrf",
		"sonic-tunnel",
		"sonic-vxlan",
		"sonic-srv6",
	}
	supported := make([]*gnmiPb.ModelData, 0, len(models))
	for _, m := range models {
		name, version := m, ""
		if i := strings.Index(m, "@"); i >= 0 {
			name, version = m[:i], m[i+1:]
		}
		supported = append(supported, &gnmiPb.ModelData{Name: name, Organization: "Agentic NetOps lab device", Version: version})
	}
	return &gnmiPb.CapabilityResponse{
		SupportedModels: supported,
		Encoding:        []gnmiPb.Encoding_{gnmiPb.Encoding_JSON, gnmiPb.Encoding_JSON_IETF},
		GnmiVersion:     "0.8.0",
	}, nil
}

// ---------------------------------------------------------------------------
// gNMI: Get
// ---------------------------------------------------------------------------

func (s *Server) Get(ctx context.Context, req *gnmiPb.GetRequest) (*gnmiPb.GetResponse, error) {
	for _, p := range req.Path {
		doc, err := s.resolve(p.String())
		if err != nil {
			return nil, status.Error(codes.InvalidArgument, err.Error())
		}
		_ = doc
	}
	// Respond with a single notification containing the first path subtree.
	var doc []byte
	if len(req.Path) > 0 {
		d, err := s.resolve(req.Path[0].String())
		if err != nil {
			return nil, status.Error(codes.InvalidArgument, err.Error())
		}
		doc = d
	}
	return &gnmiPb.GetResponse{
		Notification: &gnmiPb.Notification{
			Timestamp: time.Now().UTC().UnixNano(),
			Update: []*gnmiPb.TypedValue{{
				Path: req.Path[0],
				Value: &gnmiPb.TypedValue_JsonIetfVal{
					JsonIetfVal: doc,
				},
			}},
		},
	}, nil
}

// resolve returns the JSON_IETF document for a gNMI path, or an empty
// (valid) JSON value when the path is recognized but currently empty.
func (s *Server) resolve(pathStr string) ([]byte, error) {
	p, err := ParsePath(pathStr)
	if err != nil {
		return nil, err
	}
	var v any
	switch p.Model {
	case "openconfig-interfaces":
		v = s.viewInterfaces(p)
	case "openconfig-network-instance":
		v = s.viewNetworkInstance(p)
	case "openconfig-bgp":
		v = s.viewBgp(p)
	case "openconfig-vlan":
		v = s.viewVlan(p)
	case "sonic-telemetry":
		v = s.viewTelemetry(p)
	case "sonic-vrf":
		v = s.viewSimpleTable("VRF")
	case "sonic-tunnel":
		v = s.viewSimpleTable("VXLAN_TUNNEL")
	case "sonic-vxlan":
		v = s.viewVxlan(p)
	case "sonic-srv6":
		v = s.viewSrv6(p)
	default:
		v = map[string]any{}
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return b, nil
}

func (s *Server) viewInterfaces(p *Path) any {
	names := p.Names()
	ifName := ""
	for i, n := range names {
		if n == "interface" && i+1 < len(names) {
			ifName = p.KeyAt(i, "name")
		}
	}
	// Which sub-leaf is requested?
	last := ""
	if len(names) > 0 {
		last = names[len(names)-1]
	}
	if ifName != "" && (last == "ip" || last == "counters" || last == "description") {
		st := s.stateHash("INTERFACE_STATE|" + ifName)
		cnt := s.stateHash("IF_COUNTERS|" + ifName)
		addrs := s.stateHash("INTF_ADDRS|" + ifName)
		cfg := s.cfgHash("INTF|" + ifName)
		iface := map[string]any{
			"name": ifName,
			"state": map[string]any{
				"oper-status": mapStatus(st["oper"]),
				"ifindex":     st["ifindex"],
				"mtu":         st["mtu"],
			},
		}
		if last == "counters" || last == "out-octets" || last == "in-octets" {
			iface["state"].(map[string]any)["counters"] = map[string]any{
				"in-octets":  cnt["in-octets"],
				"out-octets": cnt["out-octets"],
				"in-pkts":    cnt["in-pkts"],
				"out-pkts":   cnt["out-pkts"],
			}
		}
		if last == "description" {
			iface["config"] = map[string]any{"description": cfg["description"]}
		}
		if last == "ip" {
			sub := map[string]any{
				"index": 0,
				"ipv6": map[string]any{
					"addresses": map[string]any{
						"address": []any{map[string]any{
							"ip":    addrs["ipv6"],
							"state": map[string]any{"ip": addrs["ipv6"]},
						}},
					},
				},
				"ipv4": map[string]any{
					"addresses": map[string]any{
						"address": []any{map[string]any{
							"ip":    addrs["ipv4"],
							"state": map[string]any{"ip": addrs["ipv4"]},
						}},
					},
				},
			}
			iface["subinterfaces"] = map[string]any{"subinterface": []any{sub}}
		}
		return map[string]any{"interfaces": map[string]any{"interface": []any{iface}}}
	}
	// Full interface list
	list := []any{}
	seen := map[string]bool{}
	for _, key := range s.stateTableKeys("INTERFACE_STATE") {
		ifn := strings.TrimPrefix(key, "INTERFACE_STATE|")
		if seen[ifn] || ifn == "" {
			continue
		}
		seen[ifn] = true
		st := s.stateHash(key)
		list = append(list, map[string]any{
			"name":  ifn,
			"state": map[string]any{"oper-status": mapStatus(st["oper"]), "ifindex": st["ifindex"], "mtu": st["mtu"]},
		})
	}
	if len(list) == 0 {
		return map[string]any{"interfaces": map[string]any{}}
	}
	return map[string]any{"interfaces": map[string]any{"interface": list}}
}

func mapStatus(oper string) string {
	switch oper {
	case "up":
		return "UP"
	case "down":
		return "DOWN"
	case "unknown":
		return "UNKNOWN"
	case "":
		return "UNKNOWN"
	default:
		return strings.ToUpper(oper)
	}
}

func (s *Server) viewNetworkInstance(p *Path) any {
	names := p.Names()
	joined := strings.Join(names, "/")
	// .../network-instance/name  (list of names)
	for i, n := range names {
		if n == "network-instance" && i+1 < len(names) && names[i+1] == "name" {
			nis := []any{}
			for _, key := range s.stateTableKeys("NI_NAMES") {
				nis = append(nis, strings.TrimPrefix(key, "NI_NAMES|"))
			}
			if len(nis) == 0 {
				nis = append(nis, "default")
			}
			return map[string]any{"network-instances": map[string]any{"network-instance": nis}}
		}
	}
	// BGP session state / afi-safi / global config
	if strings.Contains(joined, "session-state") {
		neighbors := []any{}
		for _, key := range s.stateTableKeys("BGP_SESSION") {
			ip := strings.TrimPrefix(key, "BGP_SESSION|")
			st := s.stateHash(key)
			neighbors = append(neighbors, map[string]any{
				"name":  ip,
				"state": map[string]any{"session-state": st["state"]},
			})
		}
		if len(neighbors) == 0 {
			return map[string]any{"network-instances": map[string]any{}}
		}
		return map[string]any{
			"network-instances": map[string]any{"network-instance": []any{map[string]any{
				"name": "default",
				"protocols": map[string]any{"protocol": []any{map[string]any{
					"identifier": "BGP",
					"name":       "BGP",
					"neighbors":  map[string]any{"neighbor": neighbors},
				}}},
			}}},
		}
	}
	if strings.Contains(joined, "afi-safi") {
		afis := []any{map[string]any{
			"afi-safi-name": "L2VPN_EVPN",
			"state":         map[string]any{"enabled": true},
		}}
		return map[string]any{
			"network-instances": map[string]any{"network-instance": []any{map[string]any{
				"name": "default",
				"protocols": map[string]any{"protocol": []any{map[string]any{
					"identifier": "BGP",
					"name":       "BGP",
					"neighbors": map[string]any{"neighbor": []any{map[string]any{
						"afi-safis": map[string]any{"afi-safi": afis},
					}}},
				}}},
			}}},
		}
	}
	if strings.Contains(joined, "global/config/as") || (len(names) > 0 && names[len(names)-1] == "as") {
		g := s.cfgHash("BGP_GLOBALS|global")
		if g["asn"] == "" {
			return map[string]any{"network-instances": map[string]any{}}
		}
		return map[string]any{
			"network-instances": map[string]any{"network-instance": []any{map[string]any{
				"name": "default",
				"protocols": map[string]any{"protocol": []any{map[string]any{
					"identifier": "BGP",
					"name":       "BGP",
					"global":     map[string]any{"config": map[string]any{"as": g["asn"]}},
				}}},
			}}},
		}
	}
	// EVPN route tables
	if strings.Contains(joined, "route-table") {
		rtType := ""
		for i, n := range names {
			if n == "route-table" {
				rtType = p.KeyAt(i, "type")
			}
		}
		key := "EVPN_ROUTE|" + rtType
		st := s.stateHash(key)
		routes := []any{}
		if st["routes"] != "" {
			_ = json.Unmarshal([]byte(st["routes"]), &routes)
		}
		if len(routes) == 0 {
			return map[string]any{"network-instances": map[string]any{"network-instance": []any{map[string]any{
				"evpn": map[string]any{"route-tables": map[string]any{"route-table": []any{}}},
			}}}}
		}
		return map[string]any{
			"network-instances": map[string]any{"network-instance": []any{map[string]any{
				"evpn": map[string]any{"route-tables": map[string]any{"route-table": []any{map[string]any{
					"type":   rtType,
					"routes": map[string]any{"route": routes},
				}}}},
			}}},
		}
	}
	// Default: list of network instances
	nis := []any{}
	for _, key := range s.stateTableKeys("NI_NAMES") {
		nis = append(nis, strings.TrimPrefix(key, "NI_NAMES|"))
	}
	if len(nis) == 0 {
		nis = append(nis, "default")
	}
	return map[string]any{"network-instances": map[string]any{"network-instance": []any{
		map[string]any{"name": "default"},
	}}}
}

func (s *Server) viewBgp(p *Path) any {
	g := s.cfgHash("BGP_GLOBALS|global")
	sessions := []any{}
	for _, key := range s.stateTableKeys("BGP_SESSION") {
		ip := strings.TrimPrefix(key, "BGP_SESSION|")
		st := s.stateHash(key)
		sessions = append(sessions, map[string]any{"neighbor": ip, "state": st["state"]})
	}
	return map[string]any{
		"bgp": map[string]any{
			"global": map[string]any{"as": g["asn"], "router-id": g["lo"]},
			"neighbors": map[string]any{
				"neighbor": sessions,
			},
		},
	}
}

func (s *Server) viewVlan(p *Path) any {
	vlans := []any{}
	for _, key := range s.stateTableKeys("VLAN_STATE") {
		vid := strings.TrimPrefix(key, "VLAN_STATE|")
		st := s.stateHash(key)
		vlans = append(vlans, map[string]any{"id": vid, "name": st["name"], "state": map[string]any{"bridge": st["bridge"]}})
	}
	if len(vlans) == 0 {
		return map[string]any{"vlans": map[string]any{}}
	}
	return map[string]any{"vlans": map[string]any{"vlan": vlans}}
}

func (s *Server) viewTelemetry(p *Path) any {
	h := s.cfgHash("TELEMETRY|gnmi")
	server := map[string]any{"name": "gnmi"}
	for k, v := range h {
		server[k] = v
	}
	return map[string]any{"sonic-telemetry": map[string]any{"TELEMETRY": map[string]any{"SERVER": []any{server}}}}
}

func (s *Server) viewSimpleTable(table string) any {
	rows := []any{}
	for _, key := range s.cfgTableKeys(table) {
		h := s.cfgHash(key)
		m := map[string]any{}
		for k, v := range h {
			m[k] = v
		}
		rows = append(rows, m)
	}
	root := table
	if len(rows) == 0 {
		return map[string]any{"sonic-tunnel": map[string]any{root: map[string]any{}}}
	}
	return map[string]any{"sonic-tunnel": map[string]any{root: rows}}
}

func (s *Server) viewVxlan(p *Path) any {
	names := p.Names()
	if len(names) > 0 && names[0] == "VXLAN_TUNNEL" {
		rows := []any{}
		for _, key := range s.cfgTableKeys("VXLAN_TUNNEL") {
			h := s.cfgHash(key)
			rows = append(rows, map[string]any{"name": strings.TrimPrefix(key, "VXLAN_TUNNEL|"), "src_ip": h["src_ip"]})
		}
		if len(rows) == 0 {
			// Empty table: emit no value (gnmic prints nothing, exit 0).
			return nil
		}
		return map[string]any{"sonic-vxlan": map[string]any{"VXLAN_TUNNEL": rows}}
	}
	return s.viewSimpleTable("VXLAN_TUNNEL")
}

func (s *Server) viewSrv6(p *Path) any {
	names := p.Names()
	if len(names) == 0 {
		// Root: summarize all SRv6 tables
		out := map[string]any{}
		for _, t := range []string{"SRV6_GLOBAL", "SRV6_LOCATOR", "SRV6_END", "SRV6_END_DT46", "SRV6_SID_LIST", "SRV6_POLICY", "SRV6_DECAPSULATION"} {
			rows := []any{}
			for _, key := range s.cfgTableKeys(t) {
				h := s.cfgHash(key)
				m := map[string]any{}
				for k, v := range h {
					m[k] = v
				}
				rows = append(rows, m)
			}
			if len(rows) > 0 {
				out[t] = rows
			}
		}
		return map[string]any{"sonic-srv6": out}
	}
	root := names[0]
	switch root {
	case "SRV6_GLOBAL":
		h := s.cfgHash("SRV6_GLOBAL|default")
		if len(h) == 0 {
			return nil
		}
		row := map[string]any{"name": "default"}
		for k, v := range h {
			row[k] = v
		}
		if len(names) > 1 {
			return map[string]any{"sonic-srv6": map[string]any{"SRV6_GLOBAL": map[string]any{"SRV6_GLOBAL_LIST": []any{row}}}}
		}
		return map[string]any{"sonic-srv6": map[string]any{"SRV6_GLOBAL": map[string]any{"SRV6_GLOBAL_LIST": []any{row}}}}
	case "SRV6_LOCATOR", "SRV6_END", "SRV6_END_DT46", "SRV6_SID_LIST", "SID_LIST", "SRV6_POLICY", "POLICY", "SRV6_DECAPSULATION":
		realTable := root
		if root == "SID_LIST" {
			realTable = "SRV6_SID_LIST"
		}
		if root == "POLICY" {
			realTable = "SRV6_POLICY"
		}
		rows := []any{}
		for _, key := range s.cfgTableKeys(realTable) {
			h := s.cfgHash(key)
			m := map[string]any{"name": strings.TrimPrefix(key, realTable+"|")}
			for k, v := range h {
				m[k] = v
			}
			if realTable == "SRV6_SID_LIST" && h["sids"] != "" {
				var sids []string
				_ = json.Unmarshal([]byte(h["sids"]), &sids)
				m["sids"] = sids
			}
			rows = append(rows, m)
		}
		if len(rows) == 0 {
			return nil
		}
		return map[string]any{"sonic-srv6": map[string]any{root: rows}}
	case "SRV6_COUNTERS":
		rows := []any{}
		for _, key := range s.stateTableKeys("SRV6_COUNTERS") {
			sid := strings.TrimPrefix(key, "SRV6_COUNTERS|")
			st := s.stateHash(key)
			rows = append(rows, map[string]any{"sid": sid, "mysid": st["mysid"]})
		}
		if len(rows) == 0 {
			return nil
		}
		return map[string]any{"sonic-srv6": map[string]any{"SRV6_COUNTERS": rows}}
	case "BEHAVIORS":
		rows := []any{}
		for _, key := range s.stateTableKeys("BEHAVIORS") {
			sid := strings.TrimPrefix(key, "BEHAVIORS|")
			st := s.stateHash(key)
			rows = append(rows, map[string]any{"sid": sid, "behavior": st["behavior"], "vrf": st["vrf"]})
		}
		if len(rows) == 0 {
			return nil
		}
		return map[string]any{"sonic-srv6": map[string]any{"BEHAVIORS": rows}}
	default:
		return nil
	}
}

// ---------------------------------------------------------------------------
// gNMI: Set
// ---------------------------------------------------------------------------

// intendedKey is the metadata key that marks a Set as intended (managed)
// state for drift restoration.
const IntendedMetadataKey = "agentic-netops-intended"

func (s *Server) Set(ctx context.Context, req *gnmiPb.SetRequest) (*gnmiPb.SetResponse, error) {
	intended := false
	if md, ok := metadata.FromIncomingContext(ctx); ok {
		if v := md.Get(IntendedMetadataKey); len(v) > 0 && v[0] != "false" {
			intended = true
		}
	}
	now := time.Now().UTC().UnixNano()
	responses := make([]*gnmiPb.SetResponse_Response, 0, len(req.Update)+len(req.Replace)+len(req.Delete))
	for _, u := range req.Update {
		if err := s.applyUpdate(u.Path.String(), jsonIETFValue(u.Value), true); err != nil {
			responses = append(responses, &gnmiPb.SetResponse_Response{
				Path: u.Path, Timestamp: now,
				Result: gnmiPb.SetResponse_INVALID_PATH,
				Err:    &gnmiPb.Error{Message: err.Error()},
			})
			continue
		}
		if intended {
			s.recordIntended(u.Path.String())
		}
		responses = append(responses, &gnmiPb.SetResponse_Response{
			Path: u.Path, Timestamp: now, Result: gnmiPb.SetResponse_OK,
		})
	}
	for _, u := range req.Replace {
		if err := s.applyUpdate(u.Path.String(), jsonIETFValue(u.Value), false); err != nil {
			responses = append(responses, &gnmiPb.SetResponse_Response{
				Path: u.Path, Timestamp: now, Result: gnmiPb.SetResponse_INVALID_PATH,
				Err: &gnmiPb.Error{Message: err.Error()},
			})
			continue
		}
		if intended {
			s.recordIntended(u.Path.String())
		}
		responses = append(responses, &gnmiPb.SetResponse_Response{
			Path: u.Path, Timestamp: now, Result: gnmiPb.SetResponse_OK,
		})
	}
	for _, d := range req.Delete {
		s.deletePath(d.String())
		responses = append(responses, &gnmiPb.SetResponse_Response{
			Path: d, Timestamp: now, Result: gnmiPb.SetResponse_OK,
		})
	}
	return &gnmiPb.SetResponse{Timestamp: now, Response: responses}, nil
}

func jsonIETFValue(tv *gnmiPb.TypedValue) string {
	if tv == nil {
		return ""
	}
	switch v := tv.Value.(type) {
	case *gnmiPb.TypedValue_JsonIetfVal:
		return string(v.JsonIetfVal)
	case *gnmiPb.TypedValue_JsonVal:
		return string(v.JsonVal)
	case *gnmiPb.TypedValue_StringVal:
		return v.StringVal
	case *gnmiPb.TypedValue_IntVal:
		return fmt.Sprint(v.IntVal)
	case *gnmiPb.TypedValue_UintVal:
		return fmt.Sprint(v.UintVal)
	case *gnmiPb.TypedValue_BoolVal:
		return fmt.Sprint(v.BoolVal)
	default:
		return ""
	}
}

func (s *Server) recordIntended(path string) {
	raw, _ := json.Marshal(path)
	_ = s.cfgc.HSet("INTENDED|"+hashPath(path), map[string]string{"path": path, "value": string(raw)})
}

func hashPath(p string) string {
	var h uint32 = 2166136261
	for i := 0; i < len(p); i++ {
		h ^= uint32(p[i])
		h *= 16777619
	}
	return fmt.Sprintf("%08x", h)
}

// applyUpdate maps a gNMI path + JSON value to redis CONFIG_DB writes.
func (s *Server) applyUpdate(pathStr, raw string, isUpdate bool) error {
	var v any
	if strings.TrimSpace(raw) != "" {
		if err := json.Unmarshal([]byte(raw), &v); err != nil {
			return fmt.Errorf("value not JSON: %w", err)
		}
	}
	p, err := ParsePath(pathStr)
	if err != nil {
		return err
	}
	names := p.Names()

	// --- sonic-telemetry TELEMETRY SERVER port (gate Set) --------------------
	if p.Model == "sonic-telemetry" && len(names) >= 2 && names[0] == "TELEMETRY" {
		port := extractScalar(v)
		if port == "" {
			if m, ok := v.(map[string]any); ok {
				if inner, ok2 := m["SERVER"].([]any); ok2 && len(inner) > 0 {
					if srv, ok3 := inner[0].(map[string]any); ok3 {
						port = scalarStr(srv["port"])
					}
				}
			}
		}
		if port == "" {
			return fmt.Errorf("no port value in telemetry update")
		}
		return s.cfgc.HSet("TELEMETRY|gnmi", map[string]string{"port": port})
	}

	// --- BGP AS (drift managed path) ------------------------------------------
	if p.Model == "openconfig-network-instance" {
		if len(names) > 0 && names[len(names)-1] == "as" {
			asn := scalarStr(v)
			if asn == "" {
				if m, ok := v.(map[string]any); ok {
					asn = scalarStr(m["as"])
				}
			}
			if asn == "" {
				return fmt.Errorf("no AS value")
			}
			return s.cfgc.HSet("BGP_GLOBALS|global", map[string]string{"as": asn})
		}
	}

	// --- interface description (unmanaged leaf) --------------------------------
	if p.Model == "openconfig-interfaces" {
		for i, n := range names {
			if n == "interface" && i+1 < len(names) && names[i+1] == "config" && len(names) >= 3 && names[len(names)-1] == "description" {
				ifn := p.KeyAt(i, "name")
				desc := scalarStr(v)
				return s.cfgc.HSet("INTF|"+ifn, map[string]string{"description": desc})
			}
		}
	}

	// --- sonic-srv6 tables ------------------------------------------------------
	if p.Model == "sonic-srv6" && len(names) > 0 {
		return s.applySrv6(names[0], v)
	}

	// --- abstract provider paths ------------------------------------------------
	switch {
	case p.Model == "" && len(names) == 2 && names[0] == "interfaces" && names[1] == "interface":
		return s.applyAbstractInterfaces(v)
	case p.Model == "" && len(names) == 3 && names[0] == "protocols" && names[1] == "bgp" && names[2] == "neighbors":
		return s.applyAbstractBgp(v)
	case p.Model == "" && len(names) == 2 && names[0] == "network-instances" && names[1] == "network-instance":
		return s.applyAbstractNI(v)
	case p.Model == "" && len(names) == 3 && names[0] == "network-instances" && names[1] == "network-instance" && names[2] == "l3vni":
		return s.applyAbstractL3VNI(v)
	case p.Model == "" && len(names) == 3 && names[0] == "network-instances" && names[1] == "network-instance" && names[2] == "bridges":
		return s.applyAbstractBridges(v)
	case p.Model == "" && len(names) == 3 && names[0] == "network-instances" && names[1] == "network-instance" && names[2] == "evpn":
		return s.applyAbstractEVPN(v)
	}
	return fmt.Errorf("unsupported set path %q", pathStr)
}

func (s *Server) applySrv6(table string, v any) error {
	switch table {
	case "SRV6_GLOBAL":
		m, ok := v.(map[string]any)
		if !ok {
			return fmt.Errorf("SRV6_GLOBAL expects object")
		}
		locator := scalarStr(m["locator-prefix"])
		if locator == "" {
			locator = scalarStr(m["locator"])
		}
		if locator == "" {
			return fmt.Errorf("no locator-prefix")
		}
		return s.cfgc.HSet("SRV6_GLOBAL|default", map[string]string{"locator": locator})
	case "MYSID":
		list, ok := asList(v)
		if !ok {
			return fmt.Errorf("MYSID expects list")
		}
		for _, e := range list {
			m, ok := e.(map[string]any)
			if !ok {
				continue
			}
			sid := scalarStr(m["sid"])
			if sid == "" {
				continue
			}
			behavior := scalarStr(m["behavior"])
			vrf := scalarStr(m["vrf"])
			if behavior == "End.DT46" {
				_ = s.cfgc.HSet("SRV6_END_DT46|"+sid, map[string]string{"behavior": "End.DT46", "vrf": vrf})
			} else {
				_ = s.cfgc.HSet("SRV6_END|"+sid, map[string]string{"behavior": behavior, "vrf": vrf})
			}
			if vrf != "" {
				_ = s.stc.HSet("BEHAVIORS|"+sid, map[string]string{"behavior": behavior, "vrf": vrf})
			}
		}
		return nil
	case "SRV6_LOCATOR", "SRV6_END", "SRV6_END_DT46", "SRV6_SID_LIST", "SRV6_POLICY", "SRV6_DECAPSULATION", "SRV6_COUNTERS":
		list, ok := asList(v)
		if !ok {
			if m, ok2 := v.(map[string]any); ok2 {
				list = []any{m}
			} else {
				return fmt.Errorf("table %s expects list", table)
			}
		}
		for _, e := range list {
			m, ok := e.(map[string]any)
			if !ok {
				continue
			}
			name := scalarStr(m["name"])
			if name == "" {
				name = scalarStr(m["sid"])
			}
			if name == "" {
				continue
			}
			kv := map[string]string{}
			for k, val := range m {
				kv[k] = scalarJSON(val)
			}
			_ = s.cfgc.HSet(table+"|"+name, kv)
		}
		return nil
	default:
		return fmt.Errorf("unsupported srv6 table %q", table)
	}
}

// Abstract provider path mappings (canonical SDC spec -> native tables).

func (s *Server) applyAbstractInterfaces(v any) error {
	list, ok := asList(v)
	if !ok {
		return fmt.Errorf("interfaces expects list")
	}
	for _, e := range list {
		m, ok := e.(map[string]any)
		if !ok {
			continue
		}
		ifn := scalarStr(m["name"])
		if ifn == "" {
			continue
		}
		if cidr4, ok4 := m["ipv4"].(string); ok4 && cidr4 != "" {
			_ = s.cfgc.HSet("INTERFACE|"+ifn+"|"+cidr4, map[string]string{})
		}
		if cidr6, ok6 := m["ipv6"].(string); ok6 && cidr6 != "" {
			_ = s.cfgc.HSet("INTERFACE|"+ifn+"|"+cidr6, map[string]string{})
		}
		if loop, ok7 := m["loopback"].(bool); ok7 && loop {
			_ = s.cfgc.HSet("LOOPBACK_INTERFACE|"+ifn+"|"+scalarStr(m["ipv4"]), map[string]string{})
		}
	}
	return nil
}

func (s *Server) applyAbstractBgp(v any) error {
	// v may carry globals + neighbors
	m, ok := v.(map[string]any)
	if !ok {
		return fmt.Errorf("bgp expects object")
	}
	if g, ok2 := m["global"].(map[string]any); ok2 {
		kv := map[string]string{}
		if asn := scalarStr(g["asn"]); asn != "" {
			kv["asn"] = asn
		}
		if lo := scalarStr(g["router-id"]); lo != "" {
			kv["lo"] = lo
		}
		if len(kv) > 0 {
			_ = s.cfgc.HSet("BGP_GLOBALS|global", kv)
		}
	}
	if list, ok2 := asList(m["neighbors"]); ok2 {
		for _, e := range list {
			nm, ok3 := e.(map[string]any)
			if !ok3 {
				continue
			}
			ip := scalarStr(nm["address"])
			if ip == "" {
				ip = scalarStr(nm["neighbor"])
			}
			if ip == "" {
				continue
			}
			_ = s.cfgc.HSet("BGP_NEIGHBOR|"+ip, map[string]string{"asn": scalarStr(nm["peer-asn"])})
		}
	}
	return nil
}

func (s *Server) applyAbstractNI(v any) error {
	// v: list of network instances (VRFs)
	list, ok := asList(v)
	if !ok {
		if m, ok2 := v.(map[string]any); ok2 {
			list = []any{m}
		} else {
			return fmt.Errorf("network-instance expects list")
		}
	}
	for _, e := range list {
		m, ok := e.(map[string]any)
		if !ok {
			continue
		}
		name := scalarStr(m["name"])
		if name == "" || name == "default" {
			continue
		}
		typ := scalarStr(m["type"])
		if typ == "DEFAULT" {
			continue
		}
		_ = s.cfgc.HSet("VRF|"+name, map[string]string{})
		kv := map[string]string{}
		if rd := scalarStr(m["rd"]); rd != "" {
			kv["rd"] = rd
		}
		kv["import"] = joinList(m["import-rt"])
		kv["export"] = joinList(m["export-rt"])
		if len(kv) > 0 {
			_ = s.cfgc.HSet("VRF_RT|"+name, kv)
		}
		_ = s.stc.HSet("NI_NAMES|"+name, map[string]string{})
	}
	return nil
}

func (s *Server) applyAbstractL3VNI(v any) error {
	list, _ := asList(v)
	for _, e := range list {
		m, ok := e.(map[string]any)
		if !ok {
			continue
		}
		vni := scalarStr(m["vni"])
		if vni == "" {
			vni = scalarStr(m["l3vni"])
		}
		if vni == "" {
			continue
		}
		_ = s.cfgc.HSet("L3VNI|"+vni, map[string]string{"vni": vni, "vrf": scalarStr(m["vrf"])})
	}
	return nil
}

func (s *Server) applyAbstractBridges(v any) error {
	list, _ := asList(v)
	for _, e := range list {
		m, ok := e.(map[string]any)
		if !ok {
			continue
		}
		vni := scalarStr(m["l2vni"])
		if vni == "" {
			vni = scalarStr(m["vni"])
		}
		br := scalarStr(m["bridge"])
		if br == "" {
			br = scalarStr(m["name"])
		}
		if br == "" {
			continue
		}
		_ = s.cfgc.HSet("L2VNI|"+vni, map[string]string{"vni": vni, "bridge": br})
		for _, portAny := range asList(m["ports"]) {
			if port, ok2 := portAny.(string); ok2 && port != "" {
				_ = s.cfgc.HSet("BRIDGE_VLAN_MEMBER|"+br+"|"+port, map[string]string{})
			}
		}
	}
	return nil
}

func (s *Server) applyAbstractEVPN(v any) error {
	// type5 routes: record for FRR rendering (informational in MVP)
	return nil
}

func (s *Server) deletePath(pathStr string) {
	p, err := ParsePath(pathStr)
	if err != nil {
		return
	}
	names := p.Names()
	if p.Model == "sonic-srv6" && len(names) > 0 {
		if len(names) > 1 {
			key := names[0] + "|" + p.KeyAt(1, "name")
			if key != "|" {
				_ = s.cfgc.Del(key)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// gNMI: Subscribe
// ---------------------------------------------------------------------------

func (s *Server) Subscribe(stream gnmiPb.GNMIServer_SubscribeServer) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	sub := first.Subscribe
	if sub == nil {
		return status.Error(codes.InvalidArgument, "missing subscribe params")
	}
	paths := sub.Path
	if len(paths) == 0 && sub.Prefix != nil {
		paths = []*gnmiPb.Path{sub.Prefix}
	}
	if len(paths) == 0 {
		return status.Error(codes.InvalidArgument, "no paths")
	}
	for _, pth := range paths {
		_ = stream.Send(&gnmiPb.SubscribeResponse{
			Response: &gnmiPb.SubscribeResponse_Update{
				Update: &gnmiPb.Notification{
					Timestamp: time.Now().UTC().UnixNano(),
					Prefix:    sub.Prefix,
					Update: []*gnmiPb.TypedValue{{
						Path:  pth,
						Value: &gnmiPb.TypedValue_StringVal{StringVal: "q"},
					}},
				},
			},
		})
		doc, err := s.resolve(pth.String())
		if err != nil {
			continue
		}
		_ = stream.Send(&gnmiPb.SubscribeResponse{
			Response: &gnmiPb.SubscribeResponse_Update{
				Update: &gnmiPb.Notification{
					Timestamp: time.Now().UTC().UnixNano(),
					Prefix:    sub.Prefix,
					Update: []*gnmiPb.TypedValue{{
						Path:  pth,
						Value: &gnmiPb.TypedValue_JsonIetfVal{JsonIetfVal: doc},
					}},
				},
			},
		})
	}
	_ = stream.Send(&gnmiPb.SubscribeResponse{Response: &gnmiPb.SubscribeResponse_SyncResponse{SyncResponse: true}})
	if sub.Mode == gnmiPb.SubscriptionMode_SAMPLE || sub.Mode == gnmiPb.SubscriptionMode_STREAM {
		// Keep the stream open until the client cancels.
		<-stream.Context().Done()
	}
	return nil
}

// ---------------------------------------------------------------------------
// Serving: dual TLS/plaintext listener
// ---------------------------------------------------------------------------

// Serve starts the gRPC server on cfg.Addr. If CertDir is set, connections
// with a TLS ClientHello get mTLS (client cert required, CA-verified);
// plaintext gRPC connections are also accepted (lab suites use both).
func (s *Server) Serve() error {
	lis, err := net.Listen("tcp", s.cfg.Addr)
	if err != nil {
		return err
	}
	var tlsCfg *tls.Config
	if s.cfg.CertDir != "" {
		cert, err := tls.LoadX509KeyPair(s.cfg.CertDir+"/gnmi.crt", s.cfg.CertDir+"/gnmi.key")
		if err == nil {
			caPEM, err2 := os.ReadFile(s.cfg.CertDir + "/ca.crt")
			if err2 == nil {
				pool := x509.NewCertPool()
				pool.AppendCertsFromPEM(caPEM)
				tlsCfg = &tls.Config{
					Certificates: []tls.Certificate{cert},
					ClientAuth:   tls.RequireAndVerifyClientCert,
					ClientCAs:    pool,
					MinVersion:   tls.VersionTLS12,
				}
			}
		}
	}
	authUnary := authUnaryInterceptor(s.cfg.User, s.cfg.Pass)
	authStream := authStreamInterceptor(s.cfg.User, s.cfg.Pass)

	plainSrv := grpc.NewServer(grpc.UnaryInterceptor(authUnary), grpc.StreamInterceptor(authStream))
	gnmiPb.RegisterGNMIServer(plainSrv, s)

	plainLis, tlsLis, _ := newSwitchingListener(lis, tlsCfg)
	errCh := make(chan error, 2)
	go func() { errCh <- plainSrv.Serve(plainLis) }()
	if tlsCfg != nil {
		tlsSrv := grpc.NewServer(grpc.Creds(credentials.NewTLS(tlsCfg)), grpc.UnaryInterceptor(authUnary), grpc.StreamInterceptor(authStream))
		gnmiPb.RegisterGNMIServer(tlsSrv, s)
		go func() { errCh <- tlsSrv.Serve(tlsLis) }()
	}
	return <-errCh
}
