//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// transport_ssh.go — the ssh transport (T151).
//
// Runs the host ssh client against the sonic-vm guest (contracts §3): key
// authentication, BatchMode (no prompt, ever), StrictHostKeyChecking against
// the per-lab known-hosts file, one multiplexed connection per node
// (ControlMaster=auto, bounded ControlPersist), a connect timeout. The
// context (per-op exec timeout) bounds each command. No password is used and
// nothing secret appears in argv. Commands arrive privilege-wrapped (sudo -n)
// via the per-kind profile; the transport joins them into one remote command.
//
// Error mapping (contract §3): a non-zero remote exit is an op failure with
// stderr; ssh itself failing (exit 255) is a transient executor error, with a
// host-key mismatch reported by node name.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

type sshTransport struct {
	node        string // logical node, for error reporting
	spec        transportSpec
	keyPath     string
	knownHosts  string
	controlPath string // multiplexing socket path, one per node
}

// sshArgv builds the host ssh argv for one remote command. The remote command
// is a single last argument: ssh concatenates its command arguments and the
// remote shell parses them, so quoting stays fully under our control.
func sshArgv(spec transportSpec, keyPath, knownHosts, remoteCmd string) []string {
	return []string{
		"-i", keyPath,
		"-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=yes",
		"-o", "UserKnownHostsFile=" + knownHosts,
		"-o", "ControlMaster=auto",
		"-o", "ControlPersist=30s", // bounded: the master connection closes itself
		"-o", "ConnectTimeout=10",
		"-o", "ControlPath=/tmp/.fx-ssh-%C",
		// The sonic-vm guest's sshd sends a pre-auth banner (/etc/issue);
		// the client prints it to stderr, and the server folds stderr into
		// verify errors — a healthy op would read as failed. LogLevel=ERROR
		// silences banners while keeping fatal diagnostics (host-key
		// mismatch, connect failures).
		"-o", "LogLevel=ERROR",
		spec.User + "@" + spec.Addr,
		remoteCmd,
	}
}

// sshRemoteJoin joins argv into one remote command line. Elements with shell
// metacharacters are single-quote escaped (every element survives the remote
// shell byte-for-byte); plainly safe elements stay readable.
func sshRemoteJoin(argv []string) string {
	parts := make([]string, len(argv))
	for i, a := range argv {
		if a != "" && strings.IndexFunc(a, unsafeRemoteRune) < 0 {
			parts[i] = a
			continue
		}
		parts[i] = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
	}
	return strings.Join(parts, " ")
}

// unsafeRemoteRune reports shell metacharacters (anything outside the safe set
// must be quoted, not trusted to the remote shell).
func unsafeRemoteRune(r rune) bool {
	switch {
	case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		return false
	}
	return !strings.ContainsRune("_-=/,.:+@%^", r)
}

// classifySSHError maps an ssh client failure to a transport error: a host-key
// mismatch is reported by node name; any other ssh failure is transient.
func classifySSHError(node string, exitCode int, stdout, stderr string) error {
	joined := stdout + "\n" + stderr
	if strings.Contains(joined, "HOST KEY VERIFICATION FAILED") ||
		strings.Contains(joined, "host key verification failed") ||
		strings.Contains(joined, "identification has changed") {
		return fmt.Errorf("host key mismatch for node %q: %s", node, firstLine(joined))
	}
	if exitCode == 255 {
		return fmt.Errorf("transient transport error for node %q: %s", node, firstLine(joined))
	}
	return fmt.Errorf("exit code %d", exitCode)
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return s
}

func (t *sshTransport) kind() string { return "ssh" }

func (t *sshTransport) run(ctx context.Context, argv []string, stdin []byte) (string, string, error) {
	cmdArgs := sshArgv(t.spec, t.keyPath, t.knownHosts, sshRemoteJoin(argv))
	if t.controlPath != "" {
		// A caller-supplied ControlPath (tests) replaces the default.
		for i, a := range cmdArgs {
			if strings.HasPrefix(a, "ControlPath=") {
				cmdArgs[i] = "ControlPath=" + t.controlPath
			}
		}
	}
	cmd := exec.Command("ssh", cmdArgs...)
	// Own process group: with ControlMaster/ControlPersist the ssh client can
	// fork a master daemon. CommandContext's single-process kill would reap
	// the client but NOT the daemon.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	// Drain the output ourselves through parent-held *os.File pipes. With a
	// bytes.Buffer, exec adds internal copy goroutines and Wait() blocks
	// until the pipe write-end closes — but the ControlPersist daemon calls
	// daemon()/setsid(), ESCAPING the process group while still inheriting
	// the pipe, so after a group kill Wait() could block forever and the
	// per-op deadline would never produce a response. With *os.File, Wait()
	// only reaps the process; the (abandoned) daemon holding the write-end
	// is harmless. The drains below are ours to finish and snapshot.
	outR, outW, err := os.Pipe()
	if err != nil {
		return "", "", fmt.Errorf("ssh pipes for node %q: %w", t.node, err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		return "", "", fmt.Errorf("ssh pipes for node %q: %w", t.node, err)
	}
	cmd.Stdout, cmd.Stderr = outW, errW
	var outMu, errMu sync.Mutex
	var outBuf, errBuf bytes.Buffer
	drain := func(r *os.File, mu *sync.Mutex, buf *bytes.Buffer) {
		chunk := make([]byte, 4096)
		for {
			n, rerr := r.Read(chunk)
			if n > 0 {
				mu.Lock()
				buf.Write(chunk[:n])
				mu.Unlock()
			}
			if rerr != nil {
				return
			}
		}
	}
	go drain(outR, &outMu, &outBuf)
	go drain(errR, &errMu, &errBuf)
	if len(stdin) > 0 {
		// The stdin payload (GCU patch) streams to the remote command's stdin.
		cmd.Stdin = bytes.NewReader(stdin)
	}
	if serr := cmd.Start(); serr != nil {
		outR.Close(); outW.Close(); errR.Close(); errW.Close()
		return "", "", fmt.Errorf("ssh start for node %q: %w", t.node, serr)
	}
	outW.Close() // parent keeps only the read ends from here on
	errW.Close()

	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()
	var werr error
	timedOut := false
	select {
	case werr = <-waitCh:
	case <-ctx.Done():
		// Deadline exceeded: take down the group (client + non-detached
		// children). A setsid'd mux daemon may survive, but it no longer
		// gates Wait(); close the read ends and reap.
		timedOut = true
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-waitCh
	}
	outR.Close() // ends the drains; give them a beat to land what arrived
	errR.Close()
	time.Sleep(20 * time.Millisecond)
	outMu.Lock()
	out := outBuf.String()
	outMu.Unlock()
	errMu.Lock()
	errStr := errBuf.String()
	errMu.Unlock()
	if timedOut {
		return out, errStr,
			fmt.Errorf("command timed out for node %q: context deadline exceeded", t.node)
	}
	if werr != nil {
		code := -1
		var ee *exec.ExitError
		if errors.As(werr, &ee) {
			code = ee.ExitCode()
		}
		return out, errStr, classifySSHError(t.node, code, out, errStr)
	}
	return out, scrubClientNoise(errStr), nil
}

// scrubClientNoise drops the ssh client's own benign warnings from a
// successful command's stderr. The server folds stderr into verify errors,
// and a concurrent op on the same node makes the mux client print
// "ControlSocket ... already exists, disabling multiplexing" even though the
// read succeeded — a healthy check must not fail on that. Remote command
// stderr (real diagnostics) is untouched. Evidence: p4-vlan-provision.
func scrubClientNoise(stderr string) string {
	if stderr == "" {
		return ""
	}
	kept := make([]string, 0, 4)
	for _, line := range strings.Split(stderr, "\n") {
		switch {
		case strings.Contains(line, "disabling multiplexing"),
			strings.Contains(line, "muxserver_listen"),
			strings.Contains(line, "Warning: Permanently added"):
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}
