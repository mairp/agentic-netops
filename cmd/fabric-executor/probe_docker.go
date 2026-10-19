//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// probe_docker.go — the probe-ping check, executing half.
//
// contracts/executor-transport.md §4: probe-ping runs only in a container
// listed in FABRIC_PROBE_MAP, always with docker exec, and only the fixed
// ping argv from pingArgv. Client containers are plain docker containers on
// the same host as the sonic-vs nodes — never SSH — so this reuses
// dockerTransport directly with the client container name.
package main

import (
	"context"
	"fmt"
	"strings"
)

// runProbePing execs the fixed ping argv into the client container and
// returns trimmed stdout. Error iff docker exec fails or ping exits non-zero
// (busybox ping exits 0 only when every echo was answered).
func runProbePing(ctx context.Context, container, addr string, size, count int) (string, error) {
	t := &dockerTransport{container: container}
	stdout, stderr, err := t.run(ctx, pingArgv(addr, size, count), nil)
	out := strings.TrimSpace(stdout)
	if err != nil {
		msg := strings.TrimSpace(stderr)
		if msg != "" {
			return out, fmt.Errorf("probe ping %s from %s: %v: %s", addr, container, err, msg)
		}
		return out, fmt.Errorf("probe ping %s from %s: %v", addr, container, err)
	}
	return out, nil
}
