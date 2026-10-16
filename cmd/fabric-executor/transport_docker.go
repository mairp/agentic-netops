//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// transport_docker.go — the docker transport (T147).
//
// The body is `(*server).exec` moved behind the transport interface with
// unchanged behaviour: raw HTTP against /var/run/docker.sock, exec create /
// start / demux / inspect, `exit code %d` on non-zero. stdin (the GCU patch
// payload) attaches to the exec — the `docker exec -i` equivalent.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

type dockerTransport struct {
	container string
}

// run creates and runs a docker exec, returning (stdout, stderr, error) where
// error is non-nil iff the command exited non-zero or the API call failed.
func (d *dockerTransport) run(ctx context.Context, argv []string, stdin []byte) (string, string, error) {
	spec := map[string]any{
		"AttachStdout": true,
		"AttachStderr": true,
		"AttachStdin":  len(stdin) > 0,
		"Tty":          false,
		"Cmd":          argv,
	}
	body, err := json.Marshal(spec)
	if err != nil {
		return "", "", err
	}
	resp, err := dockerHTTP(ctx, http.MethodPost, dockerAPI+"/containers/"+d.container+"/exec", bytes.NewReader(body))
	if err != nil {
		return "", "", fmt.Errorf("exec create: %w", err)
	}
	var created struct {
		ID string `json:"Id"`
	}
	if err := json.Unmarshal(resp, &created); err != nil || created.ID == "" {
		return "", "", fmt.Errorf("exec create response %q: %v", truncate(string(resp), 300), err)
	}

	// The exec start is hijacked (raw TCP after the response headers), not a
	// plain streamed response: stdin must reach the remote command AND the
	// remote command must see stdin EOF. The previous shape streamed the
	// response through http.Client — whose response body is read-only, so the
	// `io.ReadWriteCloser` assertion below silently skipped the stdin write
	// and the GCU reader blocked on stdin forever ("exec inspect timeout",
	// measured live 2026-10-15 on the sonic-vs leg: every executor GCU apply
	// hung until the 90 s deadline).
	h, err := dockerHijack(ctx, "/v1.41/exec/"+created.ID+"/start", `{"Detach": false, "Tty": false}`)
	if err != nil {
		return "", "", fmt.Errorf("exec start: %w", err)
	}
	// The stdin payload (GCU patch) rides the hijacked stream: write it, then
	// half-close so the remote command's stdin hits EOF (contract §3 — the
	// patch never crosses a command line).
	if len(stdin) > 0 {
		if _, werr := h.Write(stdin); werr != nil {
			_ = h.Close()
			return "", "", fmt.Errorf("exec stdin: %w", werr)
		}
	}
	_ = h.CloseWrite()
	stdout, stderr := demuxStream(h)
	_ = h.Close()

	// Exit status via inspect (small retry while Running settles).
	var exitCode int64 = -1
	for i := 0; i < 20; i++ {
		insp, err := dockerHTTP(ctx, http.MethodGet, dockerAPI+"/exec/"+created.ID+"/json", nil)
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

func (d *dockerTransport) kind() string { return "docker" }

func dockerHTTP(ctx context.Context, method, url string, body io.Reader) ([]byte, error) {
	resp, cleanup, err := dockerDo(ctx, method, url, body, false)
	if err != nil {
		return nil, err
	}
	defer cleanup()
	return io.ReadAll(io.LimitReader(resp, maxBodyBytes))
}

// hijackedStream is a raw post-upgrade connection to the docker daemon. After
// the handshake the wire carries the exec's stdio both ways, so Write feeds
// the remote stdin and CloseWrite delivers the stdin EOF (a half-close) the
// remote command blocks on.
type hijackedStream struct {
	conn   net.Conn
	reader *bufio.Reader
}

func (h *hijackedStream) Read(p []byte) (int, error)  { return h.reader.Read(p) }
func (h *hijackedStream) Write(p []byte) (int, error) { return h.conn.Write(p) }
func (h *hijackedStream) Close() error                { return h.conn.Close() }
func (h *hijackedStream) CloseWrite() error           { return h.conn.(interface{ CloseWrite() error }).CloseWrite() }

// dockerHijack performs the docker exec-start upgrade handshake by hand: the
// docker daemon hijacks the TCP/unix connection after the response headers and
// Go's http.Client cannot hand back a writable half-closeable stream for that
// (the docker CLI does exactly this against a raw conn).
func dockerHijack(ctx context.Context, apiPath, body string) (*hijackedStream, error) {
	d := net.Dialer{Timeout: 5 * time.Second}
	conn, err := d.DialContext(ctx, "unix", dockerSock)
	if err != nil {
		return nil, err
	}
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	} else {
		_ = conn.SetDeadline(time.Now().Add(execTimeout))
	}
	req := fmt.Sprintf(
		"POST %s HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: %d\r\n\r\n%s",
		apiPath, len(body), body)
	if _, err := conn.Write([]byte(req)); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("hijack write: %w", err)
	}
	br := bufio.NewReader(conn)
	statusLine, err := br.ReadString('\n')
	if err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("hijack status: %w", err)
	}
	if !strings.Contains(statusLine, "101") && !strings.Contains(statusLine, "200") {
		_ = conn.Close()
		return nil, fmt.Errorf("hijack unexpected status %q", strings.TrimSpace(statusLine))
	}
	// drain headers through the terminating blank line; leftover buffered
	// bytes are already stream data
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			_ = conn.Close()
			return nil, fmt.Errorf("hijack headers: %w", err)
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	return &hijackedStream{conn: conn, reader: br}, nil
}

// One transport and client for the whole process. A fresh http.Transport per
// call (the previous shape) parks every finished connection in a pool that is
// never closed, so each docker API call leaked one unix socket; the daemon hit
// its 524k descriptor cap after ~14 h on 2026-09-06 and every docker command
// on the host hung. Hijacked exec streams are closed by their owner; plain
// responses return to this pool and are reused.
var (
	dockerAPIHTTPTransport = &http.Transport{
		DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
			return net.DialTimeout("unix", dockerSock, 5*time.Second)
		},
		MaxIdleConns:        8,
		MaxIdleConnsPerHost: 8,
		IdleConnTimeout:     60 * time.Second,
	}
	dockerClient = &http.Client{Transport: dockerAPIHTTPTransport, Timeout: execTimeout}
)

func dockerDo(ctx context.Context, method, url string, body io.Reader, stream bool) (io.ReadCloser, func(), error) {
	client := dockerClient
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
