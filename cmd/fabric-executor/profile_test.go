//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// profile_test.go — the per-kind command profile (T152 privilege, T153 stdin
// payload path, T155 durable FRR file) and its use in applyFRRConf.
package main

import (
	"context"
	"encoding/base64"
	"strings"
	"testing"
)

// TestProfilePrivilege (T152): docker runs as root inside the container (no
// sudo); ssh wraps every command in `sudo -n` (verified: sudo -n true succeeds
// for admin on the sonic-vm guest).
func TestProfilePrivilege(t *testing.T) {
	if profileFor("docker").privileged {
		t.Fatal("docker profile must not wrap in sudo")
	}
	if !profileFor("ssh").privileged {
		t.Fatal("ssh profile must wrap in sudo -n")
	}
	dockerArgv := wrapPrivilege([]string{"bash", "-c", "echo hi"}, profileFor("docker"))
	if strings.Join(dockerArgv, " ") != "bash -c echo hi" {
		t.Fatalf("docker argv changed: %v", dockerArgv)
	}
	sshArgv := wrapPrivilege([]string{"bash", "-c", "echo hi"}, profileFor("ssh"))
	if strings.Join(sshArgv, " ") != "sudo -n bash -c echo hi" {
		t.Fatalf("ssh argv = %v, want sudo -n prefixed", sshArgv)
	}
}

// TestProfileStdinPayload (T153): GCU patches travel as a stdin payload on
// both kinds (docker: exec -i attach; ssh: the ssh stdin pipe) — the profile
// declares that capability and the transport delivers it.
func TestProfileStdinPayload(t *testing.T) {
	if !profileFor("docker").stdinPayload {
		t.Fatal("docker profile must carry stdin payloads (docker exec -i)")
	}
	if !profileFor("ssh").stdinPayload {
		t.Fatal("ssh profile must carry stdin payloads (ssh stdin)")
	}
}

// TestProfileFRRConfPath (T155): the durable FRR file is per kind —
// /etc/frr/bgpd.conf in the sonic-vs container; under /etc/sonic/frr/ in the
// sonic-vm guest (exact path confirmed by the p3-frr-durable proof).
func TestProfileFRRConfPath(t *testing.T) {
	if got := profileFor("docker").frrConfPath; got != "/etc/frr/bgpd.conf" {
		t.Fatalf("docker frrConfPath = %q", got)
	}
	if got := profileFor("ssh").frrConfPath; got != "/etc/sonic/frr/bgpd.conf" {
		t.Fatalf("ssh frrConfPath = %q", got)
	}
}

// TestApplyFRRConfUsesProfilePath: an frrconf op on an ssh node appends to the
// SONiC guest's durable FRR file, not the container path.
func TestApplyFRRConfUsesProfilePath(t *testing.T) {
	ft := &fakeTransport{kindStr: "ssh"}
	srv := newFakeServer(ft)
	resp := srv.applyFRRConf(context.Background(), "leaf01", []string{"vrf Blue", "vni 10007"})
	if !resp.OK {
		t.Fatalf("applyFRRConf failed: %+v", resp)
	}
	if len(ft.calls) != 1 {
		t.Fatalf("transport saw %d calls, want 1", len(ft.calls))
	}
	joined := strings.Join(ft.calls[0].argv, " ")
	if !strings.Contains(joined, "/etc/sonic/frr/bgpd.conf") {
		t.Fatalf("frrconf op did not target the ssh profile path: %s", joined)
	}
	if strings.Contains(joined, "/etc/frr/bgpd.conf") {
		t.Fatalf("frrconf op used the docker path on an ssh node: %s", joined)
	}
}

// TestApplyGCUPassesPatchOnStdin (T153): the GCU patch reaches the transport
// as the stdin payload (no base64 blob on the command line).
func TestApplyGCUPassesPatchOnStdin(t *testing.T) {
	ft := &fakeTransport{}
	srv := newFakeServer(ft)
	// A whole-table add skips the per-key table-existence probe, so the patch
	// apply is the single transport call the assertion counts.
	resp := srv.applyGCU(context.Background(), "leaf01", []map[string]any{
		{"op": "add", "path": "/VLAN", "value": map[string]any{"Vlan100": map[string]any{"vlanid": "100"}}},
	})
	if !resp.OK {
		t.Fatalf("applyGCU failed: %+v", resp)
	}
	if len(ft.calls) != 1 {
		t.Fatalf("transport saw %d calls, want 1", len(ft.calls))
	}
	if !strings.Contains(ft.calls[0].stdin, "Vlan100") {
		t.Fatalf("patch was not passed on stdin: %q", ft.calls[0].stdin)
	}
	// The patch never crosses a command line: no patch temp file, and the
	// base64 blob of the patch bytes is absent from argv (the fixed script
	// blob legitimately stays base64-encoded — it is not the payload).
	joined := strings.Join(ft.calls[0].argv, " ")
	if strings.Contains(joined, "fx-patch.json") {
		t.Fatalf("patch still travels on the command line: %s", joined)
	}
	patchB64 := base64.StdEncoding.EncodeToString(ft.calls[0].stdinBytes())
	if strings.Contains(joined, patchB64) {
		t.Fatalf("patch bytes still on the command line: %.120s", joined)
	}
}
