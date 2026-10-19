// SPDX-License-Identifier: Apache-2.0
// probe.go — the probe-ping check, pure half.
//
// contracts/executor-transport.md §2 + §4: FABRIC_PROBE_MAP is a JSON object
// mapping an attachment ("<node>/<logical-port>") to the CLIENT container that
// carries it ("leaf01/wan1" -> "clab-...-srv6-client01"). The probe-ping check
// runs only in a container listed there, always with docker exec, and only the
// fixed ping argv built here — a check naming an unregistered attachment fails
// with "no probe host for <attachment>".
//
// This file carries NO build tag on purpose: parseProbeMap, probeHost and
// pingArgv are pure, and probe_test.go must run in a plain `go test` with no
// agentic_netops_k8s tag (the rest of the package is tag-gated, so without
// the tag the package is exactly these pure definitions). The docker-executing
// half lives behind the tag in probe_docker.go.
package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// probeHosts is the parsed FABRIC_PROBE_MAP: attachment -> client container.
// Set once at startup by initProbeMap (same refusal-to-start shape as
// FABRIC_NODE_MAP in main.go); read per check by probeHost.
var probeHosts = map[string]string{}

// parseProbeMap parses the FABRIC_PROBE_MAP env value. Empty or absent means
// an empty map (no probe-ping check can then pass); invalid JSON is an error
// so the executor can refuse to start.
func parseProbeMap(raw string) (map[string]string, error) {
	m := map[string]string{}
	if strings.TrimSpace(raw) == "" {
		return m, nil
	}
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		return nil, fmt.Errorf("FABRIC_PROBE_MAP invalid: %w", err)
	}
	return m, nil
}

// initProbeMap installs the parsed probe map as the package-level table used
// by probeHost. Returns the startup-refusal error for invalid JSON.
func initProbeMap(raw string) error {
	m, err := parseProbeMap(raw)
	if err != nil {
		return err
	}
	probeHosts = m
	return nil
}

// probeHost returns the client container registered for an attachment
// ("<node>/<port>"), or the exact contract error for an unregistered one.
func probeHost(attachment string) (string, error) {
	host, ok := probeHosts[attachment]
	if !ok || host == "" {
		return "", fmt.Errorf("no probe host for %s", attachment)
	}
	return host, nil
}

// pingArgv builds the ONLY ping argv the executor will ever run. It mirrors
// the recorded DF probe from scripts/spike/evpn2-ping.sh (same shape in
// evpn3-rollback.sh): `ping -c3 -W3 -s 8900 -M do <addr>` — busybox ping in
// the client containers, -M do = don't-fragment. It is an argv slice, never a
// shell string, so addr cannot be shell-interpolated.
func pingArgv(addr string, size, count int) []string {
	return []string{
		"ping",
		"-c", strconv.Itoa(count),
		"-W", "3",
		"-s", strconv.Itoa(size),
		"-M", "do",
		addr,
	}
}
