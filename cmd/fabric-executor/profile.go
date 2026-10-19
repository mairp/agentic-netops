//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// profile.go — the per-kind command profile (T152, T153, T155).
//
// contracts/executor-transport.md §3: guest differences are handled by a
// per-kind command profile, not by the plan. docker (sonic-vs) execs into the
// container as root; ssh (sonic-vm) runs every command under `sudo -n`
// (verified: `sudo -n true` succeeds for admin on the guest). stdin payloads
// (GCU patches) travel through the transport on both kinds. The durable FRR
// file is per kind: /etc/frr/bgpd.conf in the sonic-vs container; the SONiC
// guest keeps it under /etc/sonic/frr/ (path confirmed by the p3-frr-durable
// proof).
package main

type profile struct {
	privileged   bool   // wrap commands in `sudo -n`
	stdinPayload bool   // GCU patch travels on the command's stdin
	frrConfPath  string // durable FRR file the frrconf op appends to
}

func profileFor(kind string) profile {
	if kind == "ssh" {
		return profile{privileged: true, stdinPayload: true, frrConfPath: "/etc/sonic/frr/bgpd.conf"}
	}
	return profile{stdinPayload: true, frrConfPath: "/etc/frr/bgpd.conf"}
}

// wrapPrivilege applies the profile's privilege rule to an argv.
func wrapPrivilege(argv []string, p profile) []string {
	if !p.privileged {
		return argv
	}
	return append([]string{"sudo", "-n"}, argv...)
}
