//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// fabric-executor: the sanctioned southbound write path.
//
// Why this exists (findings §4.1 + 2026-09-04 reset): gNMI Set on this SONiC
// image is broken upstream (empty scope-list in the GCU bridge), and SDC — the
// intended config engine — is unusable (placeholder images). The only write
// path ever proven against this fabric is host-side `docker exec` into the
// sonic-vs containers (GCU patches + redis + kernel). This service exposes
// exactly that, narrowly, from inside the cluster:
//
//   - it talks to /var/run/docker.sock (mounted) over raw HTTP — no docker SDK;
//   - it only execs into containers present in its node map (FABRIC_NODE_MAP,
//     logical name -> container name), so no pod can pivot to arbitrary
//     containers on the host;
//   - ops are the four proven primitives only: GCU JSON patches, redis CONFIG_DB
//     commands, kernel shell, and vtysh/bgpd.conf;
//   - it lives in agentic-netops-system behind deny-all, so the intent tier
//     (agentic-netops-agents) still has NO route to the devices (SC-005) — only
//     the SONiC provider, through this service, can touch the fabric.
//
// GCU per-key-vs-whole-table handling mirrors the bootstrap: a per-key add
// (path /TABLE/key) is promoted to a whole-table add when the table does not
// exist yet, because GCU rejects adding a child to a missing parent.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	dockerSock   = "/var/run/docker.sock"
	dockerAPI    = "http://localhost/v1.41"
	redisDB      = "4"
	execTimeout  = 90 * time.Second
	maxBodyBytes = 4 << 20
)

// ---- wire types -------------------------------------------------------------

type ApplyOp struct {
	GCU     []map[string]any `json:"gcu,omitempty"`
	Redis   []string         `json:"redis,omitempty"`
	Shell   []string         `json:"shell,omitempty"`
	VTYSh   []string         `json:"vtysh,omitempty"`
	FRRConf []string         `json:"frrconf,omitempty"`
	// OnClient scopes the op to the probe client container registered for
	// the "<node>/<port>" attachment (FABRIC_PROBE_MAP): docker exec only,
	// sh -c (busybox clients, data-model.md §8.7) — the client-addressing
	// item of contracts/fabricplan-srv6.md §3.1.
	OnClient string `json:"onClient,omitempty"`
}

type ApplyRequest struct {
	Node string    `json:"node"`
	Ops  []ApplyOp `json:"ops"`
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

type VerifyCheck struct {
	Type        string            `json:"type"`
	RedisKey    string            `json:"redisKey,omitempty"`
	RedisField  string            `json:"redisField,omitempty"`
	RedisDB     string            `json:"redisDB,omitempty"`
	MatchFields map[string]string `json:"matchFields,omitempty"`
	MinCount    int               `json:"minCount,omitempty"`
	Iface       string            `json:"iface,omitempty"`
	Master      string            `json:"master,omitempty"`
	Addr        string            `json:"addr,omitempty"`
	Vid         int64             `json:"vid,omitempty"`
	Path        string            `json:"path,omitempty"`
	Line        string            `json:"line,omitempty"`
	Command     string            `json:"command,omitempty"`
	Expect      string            `json:"expect,omitempty"`
	ProbeFrom   string            `json:"probeFrom,omitempty"`
	ProbeTo     string            `json:"probeTo,omitempty"`
	Size        int               `json:"size,omitempty"`
	Count       int               `json:"count,omitempty"`
	OnClient    string            `json:"onClient,omitempty"`
}

type VerifyRequest struct {
	Node   string        `json:"node"`
	Checks []VerifyCheck `json:"checks"`
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
	nodeMap map[string]string // logical -> container name
	trans   map[string]transport
}

// mux builds the route table; main() and the tests share it.
func (s *server) mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/v1/nodes", s.handleNodes)
	mux.HandleFunc("/v1/node/apply", s.handleApply)
	mux.HandleFunc("/v1/node/verify", s.handleVerify)
	mux.Handle("/metrics", promhttp.Handler())
	return mux
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
	cfg, err := loadTransportConfig(os.Getenv)
	if err != nil {
		fmt.Fprintf(os.Stderr, "transport config refused: %v\n", err)
		os.Exit(1)
	}
	if err := initProbeMap(os.Getenv("FABRIC_PROBE_MAP")); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	// contracts/executor-transport.md §4: the executor owns the probe table
	// and says out loud which attachments it can verify a data path from.
	keys := make([]string, 0, len(probeHosts))
	for k := range probeHosts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(os.Stderr, "probe attachment %s -> %s\n", k, probeHosts[k])
	}
	srv := &server{nodeMap: nm, trans: map[string]transport{}}
	for node := range nm {
		if sp, ok := cfg.spec(node); ok && sp.Kind == "ssh" {
			srv.trans[node] = &sshTransport{
				node:       node,
				spec:       sp,
				keyPath:    cfg.sshKey,
				knownHosts: cfg.knownHosts,
				// FABRIC_SSH_CONTROL_PATH (optional) isolates the mux socket
				// per executor instance: a second executor on the same host
				// must not ride the first one's ControlMaster, or it would
				// skip its own host-key verification (q3-transport T182).
				controlPath: os.Getenv("FABRIC_SSH_CONTROL_PATH"),
			}
		} else {
			srv.trans[node] = &dockerTransport{container: nm[node]}
		}
	}

	addr := os.Getenv("FABRIC_EXECUTOR_BIND")
	if addr == "" {
		addr = ":8084"
	}
	fmt.Printf("fabric-executor listening on %s with %d node(s)\n", addr, len(nm))
	for _, node := range ssorted(nm) {
		// The per-node kind in the log is the documented write path made
		// visible (FR-012): docker exec for sonic-vs, SSH into the guest for
		// sonic-vm; checked against /v1/nodes by the live transport suite.
		extra := ""
		if sp, ok := cfg.spec(node); ok && sp.Kind == "ssh" {
			extra = fmt.Sprintf(" addr=%s user=%s", sp.Addr, sp.User)
		}
		fmt.Printf("node %s kind=%s%s\n", node, srv.trans[node].kind(), extra)
	}
	if err := http.ListenAndServe(addr, srv.mux()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// ssorted returns the map keys sorted (helper for deterministic startup logs).
func ssorted(m map[string]string) []string {
	names := make([]string, 0, len(m))
	for k := range m {
		names = append(names, k)
	}
	sortStrings(names)
	return names
}

func (s *server) handleNodes(w http.ResponseWriter, _ *http.Request) {
	names := ssorted(s.nodeMap)
	entries := make([]map[string]string, 0, len(names))
	for _, n := range names {
		kind := "docker"
		if t := s.trans[n]; t != nil {
			kind = t.kind()
		}
		entries = append(entries, map[string]string{"name": n, "kind": kind})
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"nodes": entries})
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// nodeFor resolves a request node to the canonical site-map key. Case and
// separators are spelling, not intent: "Leaf01" and "leaf01" name the same
// device. An unknown node is still refused — this only unifies spellings of a
// node the site map already declares. Sorted so a map that spells one node two
// ways resolves deterministically.
func (s *server) nodeFor(node string) (string, bool) {
	if c, ok := s.nodeMap[node]; ok && c != "" {
		return node, true
	}
	names := ssorted(s.nodeMap)
	want := normalizeNodeName(node)
	for _, k := range names {
		if normalizeNodeName(k) == want && s.nodeMap[k] != "" {
			return k, true
		}
	}
	return "", false
}

// execNode routes one command through the node's transport, applying the
// per-kind profile (privilege wrap) first. No caller knows which transport it
// got (contracts/executor-transport.md §1).
func (s *server) execNode(ctx context.Context, node string, argv []string, stdin []byte) (string, string, error) {
	t := s.trans[node]
	if t == nil {
		// No transport table (tests, or a map built before the refactor):
		// behave exactly as the pre-transport executor did — docker exec.
		t = &dockerTransport{container: s.nodeMap[node]}
	}
	return t.run(ctx, wrapPrivilege(argv, profileFor(t.kind())), stdin)
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

// ---- apply ------------------------------------------------------------------

func (s *server) handleApply(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, 405, map[string]string{"error": "POST only"})
		return
	}
	var req ApplyRequest
	body := io.LimitReader(r.Body, maxBodyBytes)
	if err := json.NewDecoder(body).Decode(&req); err != nil {
		writeJSON(w, 400, map[string]string{"error": fmt.Sprintf("bad request: %v", err)})
		return
	}
	node, ok := s.nodeFor(req.Node)
	if !ok {
		writeJSON(w, 400, map[string]string{"error": fmt.Sprintf("node %q not in site map", req.Node)})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), execTimeout*time.Duration(maxInt(1, len(req.Ops))))
	defer cancel()

	resp := ApplyResponse{Node: req.Node, OK: true}
	for i, op := range req.Ops {
		switch {
		case op.OnClient != "":
			res := s.applyClient(ctx, op)
			res.Kind = fmt.Sprintf("ops[%d].client[%s]", i, op.OnClient)
			resp.Results = append(resp.Results, res)
		case len(op.GCU) > 0:
			res := s.applyGCU(ctx, node, op.GCU)
			res.Kind = fmt.Sprintf("ops[%d].gcu", i)
			resp.Results = append(resp.Results, res)
		case len(op.Redis) > 0:
			// Plan Redis ops are redis-cli ARGUMENTS ("hset 'VLAN|Vlan100' ..."),
			// not shell commands — run them through redis-cli on CONFIG_DB.
			// Executing them bare fails with exit 127 ("hset: command not
			// found"), which the reconciler correctly treats as fatal.
			redisCmds := make([]string, len(op.Redis))
			for j, c := range op.Redis {
				redisCmds[j] = fmt.Sprintf("redis-cli -n %s %s", redisDB, c)
			}
			res := s.applyShell(ctx, node, redisCmds, false)
			res.Kind = fmt.Sprintf("ops[%d].redis", i)
			resp.Results = append(resp.Results, res)
		case len(op.Shell) > 0:
			res := s.applyShell(ctx, node, op.Shell, false)
			res.Kind = fmt.Sprintf("ops[%d].shell", i)
			resp.Results = append(resp.Results, res)
		case len(op.VTYSh) > 0:
			res := s.applyVTYSh(ctx, node, op.VTYSh)
			res.Kind = fmt.Sprintf("ops[%d].vtysh", i)
			resp.Results = append(resp.Results, res)
		case len(op.FRRConf) > 0:
			res := s.applyFRRConf(ctx, node, op.FRRConf)
			res.Kind = fmt.Sprintf("ops[%d].frrconf", i)
			resp.Results = append(resp.Results, res)
		default:
			resp.Results = append(resp.Results, OpResult{Kind: fmt.Sprintf("ops[%d]", i), OK: false, Error: "empty op"})
		}
		if n := len(resp.Results); n > 0 {
			last := resp.Results[n-1]
			if last.OK {
				opsApplied.Inc() // writes counted; verify is never counted
			} else {
				// An empty op is a plan bug; a failed op may be a no-op retry. Either
				// way, report and stop: partial application is surfaced truthfully.
				resp.OK = false
				break
			}
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

// applyGCU validates the whole CONFIG_DB through the generic config updater.
// Per-key adds are promoted to whole-table adds when the table is absent.
func (s *server) applyGCU(ctx context.Context, node string, patch []map[string]any) OpResult {
	patchJSON, err := json.Marshal(patch)
	if err != nil {
		return OpResult{OK: false, Error: fmt.Sprintf("marshal patch: %v", err)}
	}
	for i, step := range patch {
		path, _ := step["path"].(string)
		op, _ := step["op"].(string)
		if op != "add" || !strings.HasPrefix(path, "/") {
			continue
		}
		table := strings.SplitN(strings.TrimPrefix(path, "/"), "/", 2)[0]
		if table == "" {
			continue
		}
		splits := len(strings.Split(strings.Trim(path, "/"), "/"))
		if splits < 2 {
			continue // whole-table op already
		}
		out, _, err := s.execNode(ctx, node, []string{"bash", "-c", fmt.Sprintf("redis-cli -n %s --scan --pattern '%s|*' | head -n1", redisDB, table)}, nil)
		if err != nil {
			return OpResult{OK: false, Error: fmt.Sprintf("table existence check %q: %v", table, err), Output: out}
		}
		if strings.TrimSpace(out) != "" {
			continue // table exists; per-key add is valid
		}
		// Promote: collect all keys of this table in the patch into one add.
		whole := map[string]any{}
		rest := []map[string]any{}
		for _, st := range patch {
			p, _ := st["path"].(string)
			if st["op"] == "add" && strings.HasPrefix(p, "/"+table+"/") {
				key := strings.TrimPrefix(p, "/"+table+"/")
				whole[key] = st["value"]
			} else {
				rest = append(rest, st)
			}
		}
		merged := append([]map[string]any{{"op": "add", "path": "/" + table, "value": whole}}, rest...)
		patchJSON, err = json.Marshal(merged)
		if err != nil {
			return OpResult{OK: false, Error: fmt.Sprintf("marshal promoted patch: %v", err)}
		}
		_ = i
		break // one promotion pass is sufficient: the whole-table add creates the parent
	}

	// apply_patch, then a race-tolerant confirmation. fabric daemons rewrite
	// CONFIG_DB rows while GCU holds its cached copy (vrfmgrd touched VrfBlue's
	// table mid-apply), so GCU can raise GenericConfigUpdaterError "after
	// applying patch to config, there are still some parts not updated" even
	// though the write landed. In that case we verify the intended end-state
	// directly against the live CONFIG_DB and exit 0 only when every op truly
	// took effect. GCU may also normalize depth-2 adds into depth-3 replaces
	// (/VRF/Name -> /VRF/Name/vni), so both shapes are confirmed. Values are
	// compared as strings: CONFIG_DB stores scalars as JSON text ("10007").
	const gcuScript = `import sys, json, jsonpatch, subprocess
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat

patch = json.load(sys.stdin)
try:
    GenericUpdater().apply_patch(jsonpatch.JsonPatch(patch), ConfigFormat.CONFIGDB, False, False, False, [])
    print("gcu applied:", len(patch), "op(s)")
    sys.exit(0)
except Exception as e:
    if "still some parts not updated" not in str(e):
        raise

def to_text(v):
    return v if isinstance(v, str) else json.dumps(v)

def hget(key, field):
    p = subprocess.run(["sonic-db-cli", "CONFIG_DB", "HGET", key, field],
                       capture_output=True, text=True, timeout=10)
    return p.stdout.strip()

def hexists(key):
    p = subprocess.run(["sonic-db-cli", "CONFIG_DB", "EXISTS", key],
                       capture_output=True, text=True, timeout=10)
    return p.stdout.strip() == "1"

def fail(msg):
    raise SystemExit("race-confirm failed: " + msg)

for op in patch:
    parts = [p for p in op.get("path", "").split("/") if p]
    kind = op.get("op")
    if kind not in ("add", "replace", "remove") or not (2 <= len(parts) <= 3):
        raise  # unsupported for race confirmation; surface the original error
    if kind == "remove":
        if hexists(parts[0] + "|" + parts[1]):
            fail("%s|%s still present" % (parts[0], parts[1]))
        continue
    if len(parts) == 2:
        value = op.get("value")
        if not isinstance(value, dict):
            fail("depth-2 op %s has non-object value" % op["path"])
        for field, want in value.items():
            got = hget(parts[0] + "|" + parts[1], field)
            if got != to_text(want):
                fail("%s|%s.%s = %r, want %r" % (parts[0], parts[1], field, got, to_text(want)))
    else:
        got = hget(parts[0] + "|" + parts[1], parts[2])
        if got != to_text(op.get("value")):
            fail("%s|%s.%s = %r, want %r" % (parts[0], parts[1], parts[2], got, to_text(op.get("value"))))
print("gcu applied with daemon race; end-state confirmed:", len(patch), "op(s)")`
	// The patch travels as the command's stdin payload (contract §3: docker
	// exec -i versus ssh stdin) — it never crosses a command line. The script
	// is still delivered base64-encoded (a fixed, non-secret blob) and reads
	// the patch from stdin (`json.load(sys.stdin)`).
	b64Script := base64.StdEncoding.EncodeToString([]byte(gcuScript))
	cmd := fmt.Sprintf("echo %s | base64 -d > /tmp/fx-gcu.py && python3 /tmp/fx-gcu.py", b64Script)
	out, stderr, err := s.execNode(ctx, node, []string{"bash", "-c", cmd}, patchJSON)
	if err != nil {
		return OpResult{OK: false, Error: err.Error(), Output: out + stderr}
	}
	return OpResult{OK: true, Output: strings.TrimSpace(out)}
}

// applyClient runs a client-scoped op inside the probe client container
// registered for the attachment: docker exec with sh -c only, never SSH (the
// clients are busybox-style containers, data-model.md §8.7;
// executor-transport.md §4). An attachment absent from FABRIC_PROBE_MAP is
// refused with the same message probe-ping uses.
func (s *server) applyClient(ctx context.Context, op ApplyOp) OpResult {
	host, err := probeHost(op.OnClient)
	if err != nil {
		return OpResult{OK: false, Error: err.Error()}
	}
	if len(op.Shell) == 0 {
		return OpResult{OK: false, Error: fmt.Sprintf("client op for %q must carry shell commands", op.OnClient)}
	}
	var log bytes.Buffer
	t := &dockerTransport{container: host}
	for _, c := range op.Shell {
		out, stderr, err := t.run(ctx, []string{"sh", "-c", c}, nil)
		log.WriteString("> " + oneLine(c) + "\n" + strings.TrimSpace(out))
		if strings.TrimSpace(stderr) != "" {
			log.WriteString("\n[stderr] " + strings.TrimSpace(stderr))
		}
		log.WriteString("\n")
		if err != nil {
			return OpResult{OK: false, Error: firstErr(err, stderr).Error(), Output: log.String()}
		}
	}
	return OpResult{OK: true, Output: log.String()}
}

func (s *server) applyShell(ctx context.Context, node string, cmds []string, _ bool) OpResult {
	var log bytes.Buffer
	for _, c := range cmds {
		out, stderr, err := s.execNode(ctx, node, []string{"bash", "-c", c}, nil)
		log.WriteString("> " + oneLine(c) + "\n" + strings.TrimSpace(out))
		if strings.TrimSpace(stderr) != "" {
			log.WriteString("\n[stderr] " + strings.TrimSpace(stderr))
		}
		log.WriteString("\n")
		if err != nil {
			return OpResult{OK: false, Error: err.Error(), Output: log.String()}
		}
	}
	return OpResult{OK: true, Output: log.String()}
}

func (s *server) applyVTYSh(ctx context.Context, node string, cmds []string) OpResult {
	// vtysh -c per argument, chained; failures are reported but the caller
	// treats FRR as best-effort (D-A2), so the reconciler downgrades to Degraded.
	args := []string{"vtysh"}
	for _, c := range cmds {
		args = append(args, "-c", c)
	}
	out, stderr, err := s.execNode(ctx, node, args, nil)
	if err != nil {
		return OpResult{OK: false, Error: err.Error(), Output: out + stderr}
	}
	return OpResult{OK: true, Output: strings.TrimSpace(out)}
}

func (s *server) applyFRRConf(ctx context.Context, node string, lines []string) OpResult {
	block := strings.Join(lines, "\n")
	sum := sha256.Sum256([]byte(block))
	marker := fmt.Sprintf("! agentic-netops managed block %x", sum[:8])
	payload := marker + "\n" + block
	b64 := base64.StdEncoding.EncodeToString([]byte(payload))
	// Content-address the marker instead of using the first configuration line.
	// Several revisions can legitimately begin with the same `vrf NAME`; using
	// that as the marker made later commands (notably Type-5 origination) appear
	// durable while the old block remained unchanged. vtysh has already applied
	// the same commands to running state, so appending here does not restart bgpd.
	// The durable FRR file is per kind (contract §3): /etc/frr/bgpd.conf in the
	// sonic-vs container; the sonic-vm guest keeps it under /etc/sonic/frr/.
	frrPath := profileFor("docker").frrConfPath
	if t := s.trans[node]; t != nil {
		frrPath = profileFor(t.kind()).frrConfPath
	}
	cmd := fmt.Sprintf("grep -qF %q %s 2>/dev/null || { echo %s | base64 -d >> %s; printf '\\n!\\n' >> %s; echo appended; }", marker, frrPath, b64, frrPath, frrPath)
	out, stderr, err := s.execNode(ctx, node, []string{"bash", "-c", cmd}, nil)
	if err != nil {
		return OpResult{OK: false, Error: err.Error(), Output: out + stderr}
	}
	return OpResult{OK: true, Output: strings.TrimSpace(out)}
}

func oneLine(s string) string { return strings.ReplaceAll(s, "\n", " ") }

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
	node, ok := s.nodeFor(req.Node)
	if !ok {
		writeJSON(w, 400, map[string]string{"error": fmt.Sprintf("node %q not in site map", req.Node)})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), execTimeout*time.Duration(maxInt(1, len(req.Checks))))
	defer cancel()

	resp := VerifyResponse{Node: req.Node, OK: true}
	for i, ck := range req.Checks {
		res := s.verifyOne(ctx, node, ck)
		res.Check = fmt.Sprintf("checks[%d].%s", i, ck.Type)
		resp.Results = append(resp.Results, res)
		if !res.OK {
			resp.OK = false
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *server) verifyOne(ctx context.Context, node string, ck VerifyCheck) VerifyResult {
	run := func(cmd string) (string, error) {
		out, stderr, err := s.execNode(ctx, node, []string{"bash", "-c", cmd}, nil)
		return strings.TrimSpace(out), firstErr(err, stderr)
	}
	// OnClient scopes the check into the probe client container registered
	// for the attachment (client-addressing check, contracts/fabricplan-srv6.md
	// §3.1): docker exec with sh -c only, never SSH (data-model.md §8.7).
	if ck.OnClient != "" {
		host, herr := probeHost(ck.OnClient)
		if herr != nil {
			return VerifyResult{OK: false, Error: herr.Error()}
		}
		t := &dockerTransport{container: host}
		run = func(cmd string) (string, error) {
			out, stderr, err := t.run(ctx, []string{"sh", "-c", cmd}, nil)
			return strings.TrimSpace(out), firstErr(err, stderr)
		}
	}
	// default redis DB
	db := ck.RedisDB
	if strings.TrimSpace(db) == "" {
		db = redisDB
	}

	switch ck.Type {
	case "redis-hget":
		got, err := run(fmt.Sprintf("redis-cli -n %s hget %q %q", db, ck.RedisKey, ck.RedisField))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: got}
		}
		return VerifyResult{OK: got == ck.Expect, Actual: got, Error: neqMsg(got, ck.Expect)}
	case "redis-exists":
		got, err := run(fmt.Sprintf("redis-cli -n %s exists %q", db, ck.RedisKey))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error()}
		}
		return VerifyResult{OK: got == "1", Actual: got}
	case "ip-master":
		got, err := run(fmt.Sprintf("ip -o link show %s 2>/dev/null | grep -oE 'master [^ @]+' | head -n1 | cut -d' ' -f2", ck.Iface))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: got}
		}
		return VerifyResult{OK: got == ck.Master, Actual: got, Error: neqMsg(got, ck.Master)}
	case "ip-addr":
		got, err := run(fmt.Sprintf("ip -br addr show %s 2>/dev/null | grep -oF %q | head -n1", ck.Iface, ck.Addr))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: got}
		}
		return VerifyResult{OK: got != "", Actual: got}
	case "link-vxlan-id":
		// Which VNI the kernel VXLAN device actually carries. SONiC names that
		// device after the VLAN, so a second service reusing a VLAN inherits
		// the FIRST service's device -- membership and bridge checks all pass
		// while the overlay carries the wrong VNI. Only this check sees it.
		got, err := run(fmt.Sprintf("ip -d link show %s 2>/dev/null | grep -oE 'vxlan id [0-9]+' | head -n1 | awk '{print $3}'", ck.Iface))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: got}
		}
		return VerifyResult{OK: got == ck.Expect, Actual: got, Error: neqMsg(got, ck.Expect)}
	case "bridge-vid":
		// Rows after the first are indented (port name column empty), so the
		// vid lands in $1 there and $2 on the first row — match both.
		got, err := run(fmt.Sprintf("bridge vlan show dev %s 2>/dev/null | awk -v v=%d '$1 == v || $2 == v' | wc -l", ck.Iface, ck.Vid))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: got}
		}
		return VerifyResult{OK: got != "0", Actual: got}
	case "file-contains":
		got, err := run(fmt.Sprintf("grep -cF %q %q 2>/dev/null || true", ck.Line, ck.Path))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: got}
		}
		return VerifyResult{OK: got != "0", Actual: got}
	case "vtysh-contains":
		got, err := run(fmt.Sprintf("vtysh -c %q", ck.Command))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: got}
		}
		ok := strings.Contains(got, ck.Expect)
		return VerifyResult{OK: ok, Actual: got, Error: neqContainsMsg(got, ck.Expect)}
	case "redis-hget-contains":
		got, err := run(fmt.Sprintf("redis-cli -n %s hget %q %q", db, ck.RedisKey, ck.RedisField))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: got}
		}
		ok := strings.Contains(got, ck.Expect)
		return VerifyResult{OK: ok, Actual: got, Error: neqContainsMsg(got, ck.Expect)}
	case "redis-keys-match":
		keysRaw, err := run(fmt.Sprintf("redis-cli -n %s keys %q", db, ck.RedisKey))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: keysRaw}
		}
		keys := []string{}
		for _, k := range strings.Split(strings.TrimSpace(keysRaw), "\n") {
			k = strings.TrimSpace(k)
			if k != "" {
				keys = append(keys, k)
			}
		}
		matched := 0
		for _, k := range keys {
			valsRaw, err := run(fmt.Sprintf("redis-cli -n %s hgetall %q", db, k))
			if err != nil {
				return VerifyResult{OK: false, Error: err.Error(), Actual: valsRaw}
			}
			if satisfiesAll(valsRaw, ck.MatchFields) {
				matched++
			}
		}
		min := ck.MinCount
		if min <= 0 {
			min = 1
		}
		ok := matched >= min
		msg := ""
		if !ok {
			msg = fmt.Sprintf("expected at least %d object(s) matching %v; enumerated %d, matched %d", min, ck.MatchFields, len(keys), matched)
		}
		return VerifyResult{OK: ok, Actual: fmt.Sprintf("keys=%d matched=%d", len(keys), matched), Error: msg}
	case "command":
		// contracts/fabricplan-srv6.md §2: a read-only shell command whose
		// output must contain Expect (e.g. `ip -6 route show` kernel-route
		// read-backs). Run like the other shell-backed checks.
		got, err := run(ck.Command)
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: got}
		}
		ok := strings.Contains(got, ck.Expect)
		return VerifyResult{OK: ok, Actual: got, Error: neqContainsMsg(got, ck.Expect)}
	case "probe-ping":
		// contracts/executor-transport.md §4: docker exec, fixed ping argv,
		// only into a client container registered in FABRIC_PROBE_MAP.
		host, err := probeHost(ck.ProbeFrom)
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error()}
		}
		out, err := runProbePing(ctx, host, ck.Addr, ck.Size, ck.Count)
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: out}
		}
		return VerifyResult{OK: true, Actual: out}
	default:
		return VerifyResult{OK: false, Error: "unknown check type " + ck.Type}
	}
}

func neqContainsMsg(got, want string) string {
	if strings.Contains(got, want) {
		return ""
	}
	return fmt.Sprintf("expected value to contain %q, got %q", want, got)
}

func neqMsg(got, want string) string {
	if got == want {
		return ""
	}
	return fmt.Sprintf("expected %q, got %q", want, got)
}

func firstErr(err error, stderr string) error {
	if err != nil {
		return err
	}
	if strings.TrimSpace(stderr) != "" {
		return fmt.Errorf("%s", strings.TrimSpace(stderr))
	}
	return nil
}

// satisfiesAll returns true when valsRaw (output of redis-cli hgetall) contains
// every key=value pair in match.
func satisfiesAll(valsRaw string, match map[string]string) bool {
	if len(match) == 0 {
		// An empty matchFields makes redis-keys-match a count-only check: every
		// enumerated object counts toward MinCount (the applied ACL_ENTRY check
		// asserts presence/count, not attributes). Evidence: p4-acl-trial.
		return true
	}
	// hgetall prints alternating key and value tokens, one per line.
	lines := strings.Split(strings.TrimSpace(valsRaw), "\n")
	pairs := map[string]string{}
	for i := 0; i+1 < len(lines); i += 2 {
		k := strings.TrimSpace(lines[i])
		v := strings.TrimSpace(lines[i+1])
		if k != "" {
			pairs[k] = v
		}
	}
	for k, want := range match {
		got, ok := pairs[k]
		if !ok {
			return false
		}
		// A leading "~" requests contains semantics: some applied views render
		// list-valued attributes (sonic-vm writes SAI ACL bind points as
		// "2:SAI_ACL_BIND_POINT_TYPE_PORT,SAI_ACL_BIND_POINT_TYPE_LAG"), where
		// an exact match would pin the element count and ordering.
		// Evidence: p4-acl-trial.
		if strings.HasPrefix(want, "~") {
			if !strings.Contains(got, strings.TrimPrefix(want, "~")) {
				return false
			}
			continue
		}
		if got != want {
			return false
		}
	}
	return true
}

// ---- docker exec over the raw API -------------------------------------------

// execResult carries demultiplexed output.
type execResult struct {
	stdout string
	stderr string
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
