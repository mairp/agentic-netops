// SPDX-License-Identifier: Apache-2.0
// fabric-executor: the sanctioned southbound write path.
//
// On Nokia SR Linux there is exactly one way into the device and it is the
// right one: gNMI. Set is transactional (the node builds a candidate and
// commits it per request), Get reads the same model back, and both speak
// JSON_IETF over TLS on :57400. So this service is thin on purpose:
//
//   - it dials only nodes present in its node map (FABRIC_NODE_MAP, logical
//     name -> "host:port"), so no caller can steer it at an arbitrary address;
//   - ops are one primitive — a gNMI SetRequest (deletes first, then updates);
//   - checks are one primitive — a gNMI GetRequest with content assertions;
//   - credentials come from the environment provision sets (FABRIC_GNMI_USER /
//     FABRIC_GNMI_PASS, the lab-generated user), never from the request;
//   - it lives behind the system tier's network policy, so the intent tier
//     (agentic-netops-agents) still has NO route to the devices (SC-005) — only
//     the SR Linux provider, through this service, can touch the fabric.
//
// There is no docker socket, no container exec, no CLI scraping: the SONiC
// target needed those because gNMI Set was broken on that image, and this
// target is the one where it is not.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	gnmipb "github.com/openconfig/gnmi/proto/gnmi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const (
	// setTimeout bounds one gNMI Set. SR Linux commits synchronously, so a
	// request that has not answered in this long is not slow, it is stuck.
	setTimeout = 60 * time.Second
	// getTimeout bounds one verification read (contracts/fabric-executor-api.md).
	getTimeout   = 10 * time.Second
	dialTimeout  = 15 * time.Second
	maxBodyBytes = 4 << 20

	// saveConfigPath persists the running configuration after a successful
	// apply sequence. A node that reboots with unsaved config comes back
	// without the service, and the 5-minute resync would be the only thing
	// repairing it.
	//
	// Verify live: the exact save path on 26.7 (research D2 records the
	// fallback, JSON-RPC `cli` with `save file`, if this one is not a Set
	// target on the running image).
	saveConfigPath = "/tools/system/configuration/save"
)

// ---- wire types -------------------------------------------------------------

// Op mirrors fabricplan.Op: exactly one gNMI Set per op.
type Op struct {
	GNMI *GNMISet `json:"gnmi,omitempty"`
}

type GNMISet struct {
	Updates []GNMIUpdate `json:"updates,omitempty"`
	Deletes []string     `json:"deletes,omitempty"`
}

type GNMIUpdate struct {
	Path  string          `json:"path"`
	Value json.RawMessage `json:"value"`
}

type ApplyRequest struct {
	Node string `json:"node"`
	Ops  []Op   `json:"ops"`
}

type OpResult struct {
	Kind   string `json:"kind"`
	OK     bool   `json:"ok"`
	Output string `json:"output,omitempty"`
	Error  string `json:"error,omitempty"`
}

type ApplyResponse struct {
	Node    string     `json:"node"`
	OK      bool       `json:"ok"`
	Results []OpResult `json:"results"`
}

// Check mirrors fabricplan.Check.
type Check struct {
	Type     string `json:"type"`
	Path     string `json:"path"`
	Expect   string `json:"expect,omitempty"`
	MinCount int    `json:"minCount,omitempty"`
}

type VerifyRequest struct {
	Node   string  `json:"node"`
	Checks []Check `json:"checks"`
}

type VerifyResult struct {
	Check  string `json:"check"`
	OK     bool   `json:"ok"`
	Actual string `json:"actual,omitempty"`
	Error  string `json:"error,omitempty"`
}

type VerifyResponse struct {
	Node    string         `json:"node"`
	OK      bool           `json:"ok"`
	Results []VerifyResult `json:"results"`
}

// ---- server -----------------------------------------------------------------

type server struct {
	nodeMap map[string]string // logical -> "host:port"
	user    string
	pass    string
	tls     *tls.Config // nil only when no CA is configured and verification is not skipped
}

func main() {
	raw := os.Getenv("FABRIC_NODE_MAP")
	if raw == "" {
		fmt.Fprintln(os.Stderr, "FABRIC_NODE_MAP is required")
		os.Exit(1)
	}
	nm := map[string]string{}
	if err := json.Unmarshal([]byte(raw), &nm); err != nil {
		fmt.Fprintf(os.Stderr, "FABRIC_NODE_MAP invalid: %v\n", err)
		os.Exit(1)
	}
	srv := &server{
		nodeMap: nm,
		user:    os.Getenv("FABRIC_GNMI_USER"),
		pass:    os.Getenv("FABRIC_GNMI_PASS"),
	}
	tlsCfg, err := buildTLS(os.Getenv("FABRIC_GNMI_CA"), os.Getenv("FABRIC_GNMI_SKIP_VERIFY") == "true")
	if err != nil {
		fmt.Fprintf(os.Stderr, "gNMI TLS configuration: %v\n", err)
		os.Exit(1)
	}
	srv.tls = tlsCfg

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/v1/nodes", srv.handleNodes)
	mux.HandleFunc("/v1/node/apply", srv.handleApply)
	mux.HandleFunc("/v1/node/verify", srv.handleVerify)

	addr := os.Getenv("FABRIC_EXECUTOR_BIND")
	if addr == "" {
		addr = ":8084"
	}
	fmt.Printf("fabric-executor listening on %s with %d node(s), gNMI user %q\n", addr, len(nm), srv.user)
	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := httpSrv.ListenAndServe(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// buildTLS assembles the client TLS configuration for the gNMI channel. The
// containerlab CA is the only trust anchor the lab has; InsecureSkipVerify is
// reachable ONLY through FABRIC_GNMI_SKIP_VERIFY, which provision never sets —
// a fabric whose certificate cannot be verified is not evidence of anything.
func buildTLS(caFile string, skipVerify bool) (*tls.Config, error) {
	cfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if skipVerify {
		cfg.InsecureSkipVerify = true
		return cfg, nil
	}
	if caFile == "" {
		// No CA configured: fall back to the system trust store rather than
		// silently trusting anything.
		return cfg, nil
	}
	pem, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("read CA %q: %w", caFile, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("CA %q contains no usable certificate", caFile)
	}
	cfg.RootCAs = pool
	return cfg, nil
}

func (s *server) handleNodes(w http.ResponseWriter, _ *http.Request) {
	names := make([]string, 0, len(s.nodeMap))
	for k := range s.nodeMap {
		names = append(names, k)
	}
	sortStrings(names)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"nodes": names})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// targetFor resolves a logical node name to its gNMI endpoint.
func (s *server) targetFor(node string) (string, bool) {
	if c, ok := s.nodeMap[node]; ok && c != "" {
		return c, true
	}
	// Case and separators are spelling, not intent: "Leaf01" and "leaf01" name
	// the same device. An unknown node is still refused — this only unifies
	// spellings of a node the site map already declares. Sorted so a map that
	// spells one node two ways resolves deterministically.
	names := make([]string, 0, len(s.nodeMap))
	for k := range s.nodeMap {
		names = append(names, k)
	}
	sortStrings(names)
	want := normalizeNodeName(node)
	for _, k := range names {
		if normalizeNodeName(k) == want && s.nodeMap[k] != "" {
			return s.nodeMap[k], true
		}
	}
	return "", false
}

func normalizeNodeName(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// ---- gNMI transport ---------------------------------------------------------

// dial opens one gRPC channel to a node. Callers reuse it for every op or check
// in one HTTP request and close it when they are done.
func (s *server) dial(target string) (*grpc.ClientConn, error) {
	var creds grpc.DialOption
	if s.tls != nil {
		creds = grpc.WithTransportCredentials(credentials.NewTLS(s.tls))
	} else {
		creds = grpc.WithTransportCredentials(insecure.NewCredentials())
	}
	return grpc.NewClient(target,
		creds,
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(maxBodyBytes)),
	)
}

// authContext carries the lab credentials the SR Linux gNMI server expects as
// per-RPC metadata. No client certificate is required; the CA only proves the
// node's identity to us.
func (s *server) authContext(ctx context.Context) context.Context {
	if s.user == "" && s.pass == "" {
		return ctx
	}
	return metadata.AppendToOutgoingContext(ctx, "username", s.user, "password", s.pass)
}

// ---- apply ------------------------------------------------------------------

func (s *server) handleApply(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, 405, map[string]string{"error": "POST only"})
		return
	}
	var req ApplyRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, maxBodyBytes)).Decode(&req); err != nil {
		writeJSON(w, 400, map[string]string{"error": fmt.Sprintf("bad request: %v", err)})
		return
	}
	target, ok := s.targetFor(req.Node)
	if !ok {
		writeJSON(w, 400, map[string]string{"error": fmt.Sprintf("node %q not in site map", req.Node)})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), setTimeout*time.Duration(maxInt(1, len(req.Ops)+1)))
	defer cancel()

	resp := ApplyResponse{Node: req.Node, OK: true}
	conn, err := s.dial(target)
	if err != nil {
		resp.OK = false
		resp.Results = append(resp.Results, OpResult{Kind: "dial", OK: false, Error: fmt.Sprintf("dial %s: %v", target, err)})
		writeJSON(w, http.StatusOK, resp)
		return
	}
	defer conn.Close()
	client := gnmipb.NewGNMIClient(conn)

	for i, op := range req.Ops {
		res := s.applySet(ctx, client, op)
		res.Kind = fmt.Sprintf("ops[%d].gnmi", i)
		resp.Results = append(resp.Results, res)
		if !res.OK {
			// An empty op is a plan bug; a failed op may be a transient. Either
			// way, report and stop: partial application is surfaced truthfully.
			resp.OK = false
			break
		}
	}

	// Persistence. A save failure marks the whole apply not-ok: a service that
	// is only in running configuration is one reboot away from not existing,
	// and reporting that as success is the class of lie this system forbids.
	if resp.OK && len(req.Ops) > 0 {
		res := s.saveConfig(ctx, client)
		res.Kind = "save"
		resp.Results = append(resp.Results, res)
		if !res.OK {
			resp.OK = false
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// applySet sends one op as one gNMI SetRequest. SR Linux commits the request
// atomically, and an update that matches running configuration is a no-op
// commit — which is what makes a reconcile of a converged service free.
func (s *server) applySet(ctx context.Context, client gnmipb.GNMIClient, op Op) OpResult {
	if op.GNMI == nil || (len(op.GNMI.Updates) == 0 && len(op.GNMI.Deletes) == 0) {
		return OpResult{OK: false, Error: "empty op"}
	}
	req := &gnmipb.SetRequest{}
	for _, d := range op.GNMI.Deletes {
		p, err := parsePath(d)
		if err != nil {
			return OpResult{OK: false, Error: err.Error()}
		}
		req.Delete = append(req.Delete, p)
	}
	for _, u := range op.GNMI.Updates {
		p, err := parsePath(u.Path)
		if err != nil {
			return OpResult{OK: false, Error: err.Error()}
		}
		val := []byte(u.Value)
		if len(val) == 0 {
			val = []byte("{}")
		}
		if !json.Valid(val) {
			return OpResult{OK: false, Error: fmt.Sprintf("update %s: value is not valid JSON", u.Path)}
		}
		req.Update = append(req.Update, &gnmipb.Update{
			Path: p,
			Val:  &gnmipb.TypedValue{Value: &gnmipb.TypedValue_JsonIetfVal{JsonIetfVal: val}},
		})
	}

	opCtx, cancel := context.WithTimeout(s.authContext(ctx), setTimeout)
	defer cancel()
	resp, err := client.Set(opCtx, req)
	if err != nil {
		// The node's own words, verbatim: a rendered path the model does not
		// have, a value it rejects, a leafref it cannot resolve. Paraphrasing
		// that is how an operator loses an afternoon.
		return OpResult{OK: false, Error: gnmiError(err), Output: setSummary(req)}
	}
	return OpResult{OK: true, Output: fmt.Sprintf("%s; %s", setSummary(req), setResponseSummary(resp))}
}

// saveConfig persists the running configuration (see saveConfigPath).
func (s *server) saveConfig(ctx context.Context, client gnmipb.GNMIClient) OpResult {
	p, err := parsePath(saveConfigPath)
	if err != nil {
		return OpResult{OK: false, Error: err.Error()}
	}
	opCtx, cancel := context.WithTimeout(s.authContext(ctx), setTimeout)
	defer cancel()
	_, err = client.Set(opCtx, &gnmipb.SetRequest{Update: []*gnmipb.Update{{
		Path: p,
		Val:  &gnmipb.TypedValue{Value: &gnmipb.TypedValue_JsonIetfVal{JsonIetfVal: []byte("{}")}},
	}}})
	if err != nil {
		return OpResult{OK: false, Error: gnmiError(err), Output: "save " + saveConfigPath}
	}
	return OpResult{OK: true, Output: "configuration saved"}
}

func setSummary(req *gnmipb.SetRequest) string {
	var b strings.Builder
	for _, d := range req.GetDelete() {
		b.WriteString("delete " + pathString(d) + "\n")
	}
	for _, u := range req.GetUpdate() {
		b.WriteString("update " + pathString(u.GetPath()) + "\n")
	}
	return strings.TrimSpace(b.String())
}

func setResponseSummary(resp *gnmipb.SetResponse) string {
	ops := make([]string, 0, len(resp.GetResponse()))
	for _, r := range resp.GetResponse() {
		ops = append(ops, fmt.Sprintf("%s %s", r.GetOp(), pathString(r.GetPath())))
	}
	return fmt.Sprintf("committed at %d: %s", resp.GetTimestamp(), strings.Join(ops, ", "))
}

// gnmiError renders an RPC failure with the node's message intact.
func gnmiError(err error) string {
	if st, ok := status.FromError(err); ok {
		return fmt.Sprintf("%s: %s", st.Code(), st.Message())
	}
	return err.Error()
}

// ---- verify -----------------------------------------------------------------

func (s *server) handleVerify(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, 405, map[string]string{"error": "POST only"})
		return
	}
	var req VerifyRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, maxBodyBytes)).Decode(&req); err != nil {
		writeJSON(w, 400, map[string]string{"error": fmt.Sprintf("bad request: %v", err)})
		return
	}
	target, ok := s.targetFor(req.Node)
	if !ok {
		writeJSON(w, 400, map[string]string{"error": fmt.Sprintf("node %q not in site map", req.Node)})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), getTimeout*time.Duration(maxInt(1, len(req.Checks))))
	defer cancel()

	resp := VerifyResponse{Node: req.Node, OK: true}
	conn, err := s.dial(target)
	if err != nil {
		resp.OK = false
		resp.Results = append(resp.Results, VerifyResult{Check: "dial", OK: false, Error: fmt.Sprintf("dial %s: %v", target, err)})
		writeJSON(w, http.StatusOK, resp)
		return
	}
	defer conn.Close()
	client := gnmipb.NewGNMIClient(conn)

	for i, ck := range req.Checks {
		res := s.verifyOne(ctx, client, ck)
		res.Check = fmt.Sprintf("checks[%d].%s", i, ck.Type)
		resp.Results = append(resp.Results, res)
		if !res.OK {
			resp.OK = false
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

// getResult is one Get's outcome, already reduced to the shapes the checks
// reason about: the decoded value(s), their compact JSON rendering, and
// whether the node said the path simply does not exist.
type getResult struct {
	values   []any  // one entry per returned update
	body     string // compact JSON of the first value, or of the list of them
	notFound bool
	err      error
}

func (s *server) get(ctx context.Context, client gnmipb.GNMIClient, path string) getResult {
	p, err := parsePath(path)
	if err != nil {
		return getResult{err: err}
	}
	getCtx, cancel := context.WithTimeout(s.authContext(ctx), getTimeout)
	defer cancel()
	resp, err := client.Get(getCtx, &gnmipb.GetRequest{
		Path:     []*gnmipb.Path{p},
		Type:     gnmipb.GetRequest_ALL,
		Encoding: gnmipb.Encoding_JSON_IETF,
	})
	if err != nil {
		if st, ok := status.FromError(err); ok && st.Code() == codes.NotFound {
			return getResult{notFound: true}
		}
		// A transport failure is an error, never an absence: reporting an
		// unreachable node as "the state is not there" would let a broken
		// channel masquerade as a broken service.
		return getResult{err: fmt.Errorf("%s", gnmiError(err))}
	}
	out := getResult{}
	for _, n := range resp.GetNotification() {
		for _, u := range n.GetUpdate() {
			v, err := decodeTypedValue(u.GetVal())
			if err != nil {
				return getResult{err: err}
			}
			out.values = append(out.values, v)
		}
	}
	switch len(out.values) {
	case 0:
		out.notFound = true
	case 1:
		out.body = compactJSON(out.values[0])
	default:
		out.body = compactJSON(out.values)
	}
	return out
}

func (s *server) verifyOne(ctx context.Context, client gnmipb.GNMIClient, ck Check) VerifyResult {
	res := s.get(ctx, client, ck.Path)

	switch ck.Type {
	case "gnmi-absent":
		if res.err != nil {
			return VerifyResult{OK: false, Error: res.err.Error()}
		}
		if res.notFound || len(res.values) == 0 || isNullOnly(res.values) {
			return VerifyResult{OK: true, Actual: "absent"}
		}
		return VerifyResult{OK: false, Actual: truncate(res.body, 400), Error: "expected the path to be absent"}
	}

	if res.err != nil {
		return VerifyResult{OK: false, Error: res.err.Error()}
	}
	if res.notFound {
		return VerifyResult{OK: false, Error: fmt.Sprintf("path %s returned no value", ck.Path)}
	}

	switch ck.Type {
	case "gnmi-equals":
		got := scalarString(res.values[0])
		if got == ck.Expect {
			return VerifyResult{OK: true, Actual: got}
		}
		return VerifyResult{OK: false, Actual: truncate(got, 400), Error: fmt.Sprintf("expected %q, got %q", ck.Expect, truncate(got, 400))}
	case "gnmi-contains":
		if strings.Contains(res.body, ck.Expect) {
			return VerifyResult{OK: true, Actual: truncate(res.body, 400)}
		}
		return VerifyResult{OK: false, Actual: truncate(res.body, 400),
			Error: fmt.Sprintf("expected the body to contain %q", ck.Expect)}
	case "gnmi-exists":
		if isNullOnly(res.values) {
			return VerifyResult{OK: false, Error: fmt.Sprintf("path %s exists but carries no value", ck.Path)}
		}
		return VerifyResult{OK: true, Actual: truncate(res.body, 400)}
	case "gnmi-list-min":
		min := ck.MinCount
		if min <= 0 {
			min = 1
		}
		n := listLen(res.values)
		if n >= min {
			return VerifyResult{OK: true, Actual: fmt.Sprintf("entries=%d", n)}
		}
		return VerifyResult{OK: false, Actual: fmt.Sprintf("entries=%d", n),
			Error: fmt.Sprintf("expected at least %d entrie(s) under %s, found %d", min, ck.Path, n)}
	default:
		return VerifyResult{OK: false, Error: "unknown check type " + ck.Type}
	}
}

// listLen counts how many list entries a Get answered with. SR Linux may answer
// a list path either as one update carrying a JSON array (or an object keyed by
// the list keys) or as one update per entry, and both mean the same count.
func listLen(values []any) int {
	if len(values) == 1 {
		switch v := values[0].(type) {
		case []any:
			return len(v)
		case map[string]any:
			// A single list entry returned as an object, or a container holding
			// exactly one list: unwrap a lone array member, otherwise it is one.
			if len(v) == 1 {
				for _, inner := range v {
					if arr, ok := inner.([]any); ok {
						return len(arr)
					}
				}
			}
			return 1
		case nil:
			return 0
		default:
			return 1
		}
	}
	return len(values)
}

func isNullOnly(values []any) bool {
	for _, v := range values {
		if v != nil {
			return false
		}
	}
	return true
}

// decodeTypedValue reduces a gNMI TypedValue to plain Go data. JSON_IETF is
// what this fabric asks for, but a node is free to answer a leaf with a scalar
// type and several do.
func decodeTypedValue(tv *gnmipb.TypedValue) (any, error) {
	if tv == nil {
		return nil, nil
	}
	switch v := tv.GetValue().(type) {
	case *gnmipb.TypedValue_JsonIetfVal:
		return decodeJSON(v.JsonIetfVal)
	case *gnmipb.TypedValue_JsonVal:
		return decodeJSON(v.JsonVal)
	case *gnmipb.TypedValue_StringVal:
		return v.StringVal, nil
	case *gnmipb.TypedValue_IntVal:
		return v.IntVal, nil
	case *gnmipb.TypedValue_UintVal:
		return v.UintVal, nil
	case *gnmipb.TypedValue_BoolVal:
		return v.BoolVal, nil
	case *gnmipb.TypedValue_FloatVal: //nolint:staticcheck // some targets still answer with it
		return v.FloatVal, nil
	case *gnmipb.TypedValue_DoubleVal:
		return v.DoubleVal, nil
	case *gnmipb.TypedValue_AsciiVal:
		return v.AsciiVal, nil
	case *gnmipb.TypedValue_BytesVal:
		return string(v.BytesVal), nil
	case *gnmipb.TypedValue_LeaflistVal:
		out := make([]any, 0, len(v.LeaflistVal.GetElement()))
		for _, e := range v.LeaflistVal.GetElement() {
			d, err := decodeTypedValue(e)
			if err != nil {
				return nil, err
			}
			out = append(out, d)
		}
		return out, nil
	default:
		return nil, fmt.Errorf("unsupported gNMI value type %T", tv.GetValue())
	}
}

func decodeJSON(raw []byte) (any, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, fmt.Errorf("decode JSON value: %w", err)
	}
	return v, nil
}

// scalarString renders a leaf value the way a check's Expect is written: a bare
// string, no JSON quoting. A container answer is rendered as its compact JSON
// so the mismatch message still shows what came back.
func scalarString(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case bool:
		return strconv.FormatBool(t)
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	case int64:
		return strconv.FormatInt(t, 10)
	case uint64:
		return strconv.FormatUint(t, 10)
	default:
		return compactJSON(v)
	}
}

func compactJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	return string(b)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
