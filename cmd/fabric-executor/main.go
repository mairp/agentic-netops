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
//     commands, kernel shell, vtysh/bgpd.conf (best-effort FRR);
//   - it lives in agentic-netops-system behind deny-all, so the intent tier
//     (agentic-netops-agents) still has NO route to the devices (SC-005) — only
//     the SONiC provider, through this service, can touch the fabric.
//
// GCU per-key-vs-whole-table handling mirrors the bootstrap: a per-key add
// (path /TABLE/key) is promoted to a whole-table add when the table does not
// exist yet, because GCU rejects adding a child to a missing parent.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	dockerSock   = "/var/run/docker.sock"
	dockerAPI    = "http://localhost/v1.41"
	redisDB      = "4"
	execTimeout  = 90 * time.Second
	maxBodyBytes = 4 << 20
)

// ---- wire types -------------------------------------------------------------

type ApplyRequest struct {
	Node string `json:"node"`
	Ops  []struct {
		GCU     []map[string]any `json:"gcu,omitempty"`
		Redis   []string         `json:"redis,omitempty"`
		Shell   []string         `json:"shell,omitempty"`
		VTYSh   []string         `json:"vtysh,omitempty"`
		FRRConf []string         `json:"frrconf,omitempty"`
	} `json:"ops"`
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

type VerifyRequest struct {
	Node   string `json:"node"`
	Checks []struct {
		Type       string `json:"type"`
		RedisKey   string `json:"redisKey,omitempty"`
		RedisField string `json:"redisField,omitempty"`
		Iface      string `json:"iface,omitempty"`
		Master     string `json:"master,omitempty"`
		Addr       string `json:"addr,omitempty"`
		Vid        int64  `json:"vid,omitempty"`
		Path       string `json:"path,omitempty"`
		Line       string `json:"line,omitempty"`
		Expect     string `json:"expect,omitempty"`
	} `json:"checks"`
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
	srv := &server{nodeMap: nm}

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
	fmt.Printf("fabric-executor listening on %s with %d node(s)\n", addr, len(nm))
	if err := http.ListenAndServe(addr, mux); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
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

func (s *server) containerFor(node string) (string, bool) {
	c, ok := s.nodeMap[node]
	return c, ok && c != ""
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
	container, ok := s.containerFor(req.Node)
	if !ok {
		writeJSON(w, 400, map[string]string{"error": fmt.Sprintf("node %q not in site map", req.Node)})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), execTimeout*time.Duration(maxInt(1, len(req.Ops))))
	defer cancel()

	resp := ApplyResponse{Node: req.Node, OK: true}
	for i, op := range req.Ops {
		switch {
		case len(op.GCU) > 0:
			res := s.applyGCU(ctx, container, op.GCU)
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
			res := s.applyShell(ctx, container, redisCmds, false)
			res.Kind = fmt.Sprintf("ops[%d].redis", i)
			resp.Results = append(resp.Results, res)
		case len(op.Shell) > 0:
			res := s.applyShell(ctx, container, op.Shell, false)
			res.Kind = fmt.Sprintf("ops[%d].shell", i)
			resp.Results = append(resp.Results, res)
		case len(op.VTYSh) > 0:
			res := s.applyVTYSh(ctx, container, op.VTYSh)
			res.Kind = fmt.Sprintf("ops[%d].vtysh", i)
			resp.Results = append(resp.Results, res)
		case len(op.FRRConf) > 0:
			res := s.applyFRRConf(ctx, container, op.FRRConf)
			res.Kind = fmt.Sprintf("ops[%d].frrconf", i)
			resp.Results = append(resp.Results, res)
		default:
			resp.Results = append(resp.Results, OpResult{Kind: fmt.Sprintf("ops[%d]", i), OK: false, Error: "empty op"})
		}
		if n := len(resp.Results); n > 0 && !resp.Results[n-1].OK {
			// An empty op is a plan bug; a failed op may be a no-op retry. Either
			// way, report and stop: partial application is surfaced truthfully.
			resp.OK = false
			break
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
func (s *server) applyGCU(ctx context.Context, container string, patch []map[string]any) OpResult {
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
		out, _, err := s.exec(ctx, container, []string{"bash", "-c", fmt.Sprintf("redis-cli -n %s --scan --pattern '%s|*' | head -n1", redisDB, table)})
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
	b64Patch := base64.StdEncoding.EncodeToString(patchJSON)
	b64Script := base64.StdEncoding.EncodeToString([]byte(gcuScript))
	cmd := fmt.Sprintf("echo %s | base64 -d > /tmp/fx-patch.json && echo %s | base64 -d > /tmp/fx-gcu.py && python3 /tmp/fx-gcu.py < /tmp/fx-patch.json", b64Patch, b64Script)
	out, stderr, err := s.exec(ctx, container, []string{"bash", "-c", cmd})
	if err != nil {
		return OpResult{OK: false, Error: err.Error(), Output: out + stderr}
	}
	return OpResult{OK: true, Output: strings.TrimSpace(out)}
}

func (s *server) applyShell(ctx context.Context, container string, cmds []string, _ bool) OpResult {
	var log bytes.Buffer
	for _, c := range cmds {
		out, stderr, err := s.exec(ctx, container, []string{"bash", "-c", c})
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

func (s *server) applyVTYSh(ctx context.Context, container string, cmds []string) OpResult {
	// vtysh -c per argument, chained; failures are reported but the caller
	// treats FRR as best-effort (D-A2), so the reconciler downgrades to Degraded.
	args := []string{"vtysh"}
	for _, c := range cmds {
		args = append(args, "-c", c)
	}
	out, stderr, err := s.exec(ctx, container, args)
	if err != nil {
		return OpResult{OK: false, Error: err.Error(), Output: out + stderr}
	}
	return OpResult{OK: true, Output: strings.TrimSpace(out)}
}

func (s *server) applyFRRConf(ctx context.Context, container string, lines []string) OpResult {
	block := strings.Join(lines, "\n")
	b64 := base64.StdEncoding.EncodeToString([]byte(block))
	// Idempotent: grep for the first line as the block marker before appending.
	marker := oneLine(lines[0])
	cmd := fmt.Sprintf("grep -qF %q /etc/frr/bgpd.conf 2>/dev/null || { echo %s | base64 -d >> /etc/frr/bgpd.conf; printf '\\n!\\n' >> /etc/frr/bgpd.conf; supervisorctl restart bgpd >/dev/null 2>&1 || true; echo appended; }", marker, b64)
	out, stderr, err := s.exec(ctx, container, []string{"bash", "-c", cmd})
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
	container, ok := s.containerFor(req.Node)
	if !ok {
		writeJSON(w, 400, map[string]string{"error": fmt.Sprintf("node %q not in site map", req.Node)})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), execTimeout*time.Duration(maxInt(1, len(req.Checks))))
	defer cancel()

	resp := VerifyResponse{Node: req.Node, OK: true}
	for i, ck := range req.Checks {
		res := s.verifyOne(ctx, container, ck)
		res.Check = fmt.Sprintf("checks[%d].%s", i, ck.Type)
		resp.Results = append(resp.Results, res)
		if !res.OK {
			resp.OK = false
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *server) verifyOne(ctx context.Context, container string, ck struct {
	Type       string `json:"type"`
	RedisKey   string `json:"redisKey,omitempty"`
	RedisField string `json:"redisField,omitempty"`
	Iface      string `json:"iface,omitempty"`
	Master     string `json:"master,omitempty"`
	Addr       string `json:"addr,omitempty"`
	Vid        int64  `json:"vid,omitempty"`
	Path       string `json:"path,omitempty"`
	Line       string `json:"line,omitempty"`
	Expect     string `json:"expect,omitempty"`
}) VerifyResult {
	run := func(cmd string) (string, error) {
		out, stderr, err := s.exec(ctx, container, []string{"bash", "-c", cmd})
		return strings.TrimSpace(out), firstErr(err, stderr)
	}
	switch ck.Type {
	case "redis-hget":
		got, err := run(fmt.Sprintf("redis-cli -n %s hget %q %q", redisDB, ck.RedisKey, ck.RedisField))
		if err != nil {
			return VerifyResult{OK: false, Error: err.Error(), Actual: got}
		}
		return VerifyResult{OK: got == ck.Expect, Actual: got, Error: neqMsg(got, ck.Expect)}
	case "redis-exists":
		got, err := run(fmt.Sprintf("redis-cli -n %s exists %q", redisDB, ck.RedisKey))
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
	default:
		return VerifyResult{OK: false, Error: "unknown check type " + ck.Type}
	}
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

// ---- docker exec over the raw API -------------------------------------------

// execResult carries demultiplexed output.
type execResult struct {
	stdout string
	stderr string
}

// exec creates and runs a docker exec, returning (stdout, stderr, error) where
// error is non-nil iff the command exited non-zero or the API call failed.
func (s *server) exec(ctx context.Context, container string, cmd []string) (string, string, error) {
	spec := map[string]any{
		"AttachStdout":  true,
		"AttachStderr":  true,
		"AttachStdin":   false,
		"Tty":           false,
		"Cmd":           cmd,
	}
	body, err := json.Marshal(spec)
	if err != nil {
		return "", "", err
	}
	resp, err := s.dockerHTTP(ctx, http.MethodPost, dockerAPI+"/containers/"+container+"/exec", bytes.NewReader(body))
	if err != nil {
		return "", "", fmt.Errorf("exec create: %w", err)
	}
	var created struct{ ID string `json:"Id"` }
	if err := json.Unmarshal(resp, &created); err != nil || created.ID == "" {
		return "", "", fmt.Errorf("exec create response %q: %v", truncate(string(resp), 300), err)
	}

	startBody := strings.NewReader(`{"Detach": false, "Tty": false}`)
	respStream, err := s.dockerStream(ctx, http.MethodPost, dockerAPI+"/exec/"+created.ID+"/start", startBody)
	if err != nil {
		return "", "", fmt.Errorf("exec start: %w", err)
	}
	stdout, stderr := demuxStream(respStream)
	_ = respStream.Close()

	// Exit status via inspect (small retry while Running settles).
	var exitCode int64 = -1
	for i := 0; i < 20; i++ {
		insp, err := s.dockerHTTP(ctx, http.MethodGet, dockerAPI+"/exec/"+created.ID+"/json", nil)
		if err == nil {
			var st struct {
				Running  bool  `json:"Running"`
				ExitCode int64 `json:"ExitCode"`
			}
			if json.Unmarshal(insp, &st) == nil && !st.Running {
				exitCode = st.ExitCode
				break
			}
		}
		select {
		case <-ctx.Done():
			return stdout, stderr, fmt.Errorf("exec inspect timeout")
		case <-time.After(200 * time.Millisecond):
		}
	}
	if exitCode != 0 {
		return stdout, stderr, fmt.Errorf("exit code %d", exitCode)
	}
	return stdout, stderr, nil
}

func (s *server) dockerHTTP(ctx context.Context, method, url string, body io.Reader) ([]byte, error) {
	resp, cleanup, err := s.dockerDo(ctx, method, url, body, false)
	if err != nil {
		return nil, err
	}
	defer cleanup()
	return io.ReadAll(io.LimitReader(resp, maxBodyBytes))
}

func (s *server) dockerStream(ctx context.Context, method, url string, body io.Reader) (io.ReadCloser, error) {
	resp, cleanup, err := s.dockerDo(ctx, method, url, body, true)
	if err != nil {
		return nil, err
	}
	_ = cleanup // stream owner closes the body itself
	return resp, nil
}

func (s *server) dockerDo(ctx context.Context, method, url string, body io.Reader, stream bool) (io.ReadCloser, func(), error) {
	tr := &http.Transport{
		DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
			return net.DialTimeout("unix", dockerSock, 5*time.Second)
		},
	}
	client := &http.Client{Transport: tr, Timeout: execTimeout}
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	hc, err := client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	if hc.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(hc.Body, 1024))
		hc.Body.Close()
		return nil, nil, fmt.Errorf("docker api %s %s: %d %s", method, url, hc.StatusCode, truncate(string(b), 200))
	}
	if stream {
		return hc.Body, func() {}, nil
	}
	return hc.Body, func() { hc.Body.Close() }, nil
}

// demuxStream splits docker's stdio multiplexing: 8-byte header
// [streamType, 0, 0, 0, payloadSize uint32 BE] then the payload.
func demuxStream(r io.Reader) (string, string) {
	var stdout, stderr bytes.Buffer
	br := bufio.NewReader(r)
	header := make([]byte, 8)
	for {
		if _, err := io.ReadFull(br, header); err != nil {
			break
		}
		size := binary.BigEndian.Uint32(header[4:8])
		var dst *bytes.Buffer
		switch header[0] {
		case 1:
			dst = &stdout
		case 2:
			dst = &stderr
		default:
			dst = nil
		}
		if _, err := io.CopyN(writeFn(dst), br, int64(size)); err != nil {
			break
		}
	}
	return stdout.String(), stderr.String()
}

type fnWriter func(p []byte) (int, error)

func (f fnWriter) Write(p []byte) (int, error) { return f(p) }

func writeFn(dst *bytes.Buffer) io.Writer {
	if dst == nil {
		return fnWriter(func(p []byte) (int, error) { return len(p), nil })
	}
	return dst
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
