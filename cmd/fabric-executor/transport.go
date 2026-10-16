//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// transport.go — the per-node-kind command transport (T146).
//
// contracts/executor-transport.md §1: every node command — GCU, redis, kernel
// shell, vtysh, file append — reaches the node through a transport. The server
// resolves one transport per node and no caller knows which one it got. The
// HTTP API does not change shape; only the southbound delivery does.
package main

import "context"

// transport executes argv on one node and returns stdout, stderr and an error
// that is nil only for exit code 0. stdin carries an optional payload (the GCU
// patch); implementations attach it to the remote command's stdin.
type transport interface {
	run(ctx context.Context, argv []string, stdin []byte) (stdout, stderr string, err error)
	kind() string // "docker" | "ssh"
}
