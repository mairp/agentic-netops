//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// transport_ssh_test.go — the ssh argv builder (T150): BatchMode, strict host
// key checking against the per-lab known-hosts file, one multiplexed
// connection per node with a bounded ControlPersist, a connect timeout, and
// never a secret in argv (contracts/executor-transport.md §3).
package main

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func argvContains(t *testing.T, argv []string, want string) {
	t.Helper()
	for _, a := range argv {
		if a == want {
			return
		}
	}
	t.Fatalf("argv %v does not contain %q", argv, want)
}

func TestSSHArgvBuilder(t *testing.T) {
	spec := transportSpec{Kind: "ssh", Addr: "172.31.0.21", User: "admin"}
	argv := sshArgv(spec, "/secrets/fabric-executor.key", "/secrets/known_hosts_executor", "sudo -n echo hi")

	argvContains(t, argv, "-o")
	argvContains(t, argv, "BatchMode=yes")
	argvContains(t, argv, "StrictHostKeyChecking=yes")
	argvContains(t, argv, "UserKnownHostsFile=/secrets/known_hosts_executor")
	argvContains(t, argv, "ControlMaster=auto")
	argvContains(t, argv, "ConnectTimeout=10")
	// The guest's pre-auth banner (/etc/issue) must not reach stderr: the
	// server folds stderr into verify errors, so a banner reads as failure.
	argvContains(t, argv, "LogLevel=ERROR")
	// One multiplexed connection per node, persisted for a bounded time only.
	argvContains(t, argv, "-o")
	found := false
	for _, a := range argv {
		if strings.HasPrefix(a, "ControlPersist=") {
			found = true
		}
	}
	if !found {
		t.Fatalf("argv %v has no ControlPersist", argv)
	}
	// Key authentication, no password anywhere.
	argvContains(t, argv, "-i")
	argvContains(t, argv, "/secrets/fabric-executor.key")
	argvContains(t, argv, "admin@172.31.0.21")
	joined := strings.Join(argv, " ")
	for _, secret := range []string{"password", "admin:", "YourPaSsWoRd"} {
		if strings.Contains(joined, secret) {
			t.Fatalf("argv %q contains %q", joined, secret)
		}
	}
	// The remote command is the single last argument.
	if argv[len(argv)-1] != "sudo -n echo hi" {
		t.Fatalf("remote command = %q, want the joined command last", argv[len(argv)-1])
	}
}

// TestSSHRemoteJoinQuoting: every argv element survives the remote shell
// intact — single quotes are escaped, whitespace is preserved.
func TestSSHRemoteJoinQuoting(t *testing.T) {
	got := sshRemoteJoin([]string{"bash", "-c", "echo 'a b' | grep -c x"})
	want := "bash -c 'echo '\\''a b'\\'' | grep -c x'"
	if got != want {
		t.Fatalf("sshRemoteJoin = %q, want %q", got, want)
	}
}

// TestSSHHostKeyMismatchReportedByName: a host-key failure is classified as
// such and names the node (contract §3), not just an ssh exit code.
func TestSSHHostKeyMismatchReportedByName(t *testing.T) {
	err := classifySSHError("leaf01", 255, "", "HOST KEY VERIFICATION FAILED")
	if err == nil || !strings.Contains(err.Error(), "leaf01") || !strings.Contains(err.Error(), "host key") {
		t.Fatalf("want host-key error naming leaf01, got %v", err)
	}
	err = classifySSHError("leaf01", 255, "", "Connection refused")
	if err == nil || !strings.Contains(err.Error(), "transient") {
		t.Fatalf("want transient transport error, got %v", err)
	}
}

// TestSSHRunDeadlineUnblocksHungCommand pins the ControlPersist-pipe fix: a
// hung remote command must be bounded by the context even though ssh's master
// daemon outlives the client and inherits the output pipes. A fake `ssh` on
// PATH daemonizes (setsid, like openssh's ControlPersist master) a child that
// holds the pipes forever and traps SIGTERM, so only the process-group kill
// PLUS parent-held output pipes can end the call within the deadline.
func TestSSHRunDeadlineUnblocksHungCommand(t *testing.T) {
	dir := t.TempDir()
	fake := dir + "/ssh"
	script := "#!/bin/sh\n" +
		// Daemonize in a NEW session (setsid), inheriting stdout/stderr —
		// exactly what openssh's ControlPersist master does. It survives any
		// process-group kill and would block a bytes.Buffer-based Wait().
		"setsid sleep 300 </dev/null &\n" +
		// Foreground client ignores SIGTERM and hangs until SIGKILLed.
		"trap '' TERM\n" +
		"sleep 300\n"
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	tr := &sshTransport{node: "leaf01", spec: transportSpec{Kind: "ssh", Addr: "10.255.255.1", User: "admin"}}
	tr.keyPath, tr.knownHosts = "/dev/null", "/dev/null"

	oldPath := os.Getenv("PATH")
	t.Setenv("PATH", dir+":"+oldPath)
	t.Cleanup(func() { _ = os.Setenv("PATH", oldPath) })

	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, _, err := tr.run(ctx, []string{"echo", "hi"}, nil)
	elapsed := time.Since(start)
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("want timeout error, got %v", err)
	}
	if elapsed > 10*time.Second {
		t.Fatalf("deadline did not unblock the hung command: took %s", elapsed)
	}
}

// p4-vlan-provision: a concurrent op on the same node makes the mux client
// print "ControlSocket ... already exists, disabling multiplexing" even though
// the command succeeded; the server folds stderr into verify errors, so this
// benign client warning must be scrubbed from a SUCCESSFUL command. Remote
// diagnostics stay.
func TestScrubClientNoise(t *testing.T) {
	mux := "ControlSocket /tmp/.fx-ssh-abc already exists, disabling multiplexing"
	if got := scrubClientNoise(mux); got != "" {
		t.Fatalf("mux warning must be scrubbed, got %q", got)
	}
	both := mux + "\nredis-cli: real diagnostic\n"
	if got := scrubClientNoise(both); got != "\nredis-cli: real diagnostic\n" && got != "redis-cli: real diagnostic\n" {
		t.Fatalf("remote diagnostics must survive, got %q", got)
	}
	if got := scrubClientNoise(""); got != "" {
		t.Fatalf("empty stderr must stay empty, got %q", got)
	}
}
