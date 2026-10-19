//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// config.go — transport configuration (T149).
//
// contracts/executor-transport.md §2: FABRIC_NODE_TRANSPORT optionally names
// the transport per node; a node absent there uses docker. The executor
// refuses to start when a node is ssh and the key or known-hosts file is
// missing or has wider permissions than 0600, when a kind is unknown, or when
// a node appears in FABRIC_NODE_TRANSPORT but not in FABRIC_NODE_MAP.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

type transportSpec struct {
	Kind string `json:"kind"`
	Addr string `json:"addr"`
	User string `json:"user"`
}

type transportConfig struct {
	specs      map[string]transportSpec
	sshKey     string
	knownHosts string
}

// anySSH reports whether any node is declared ssh (key material required).
func (c transportConfig) anySSH() bool {
	for _, sp := range c.specs {
		if sp.Kind == "ssh" {
			return true
		}
	}
	return false
}

func (c transportConfig) spec(node string) (transportSpec, bool) {
	sp, ok := c.specs[node]
	return sp, ok
}

func loadTransportConfig(getenv func(string) string) (transportConfig, error) {
	cfg := transportConfig{specs: map[string]transportSpec{}}

	nodeMap := map[string]string{}
	if raw := getenv("FABRIC_NODE_MAP"); raw != "" {
		if err := json.Unmarshal([]byte(raw), &nodeMap); err != nil {
			return cfg, fmt.Errorf("FABRIC_NODE_MAP invalid: %w", err)
		}
	}

	if raw := getenv("FABRIC_NODE_TRANSPORT"); raw != "" {
		decls := map[string]transportSpec{}
		if err := json.Unmarshal([]byte(raw), &decls); err != nil {
			return cfg, fmt.Errorf("FABRIC_NODE_TRANSPORT invalid: %w", err)
		}
		for node, sp := range decls {
			if _, ok := nodeMap[node]; !ok {
				return cfg, fmt.Errorf("node %q in FABRIC_NODE_TRANSPORT but not in FABRIC_NODE_MAP", node)
			}
			if sp.Kind != "docker" && sp.Kind != "ssh" {
				return cfg, fmt.Errorf("node %q: unknown transport kind %q (want docker or ssh)", node, sp.Kind)
			}
			if sp.Kind == "ssh" {
				if strings.TrimSpace(sp.Addr) == "" {
					return cfg, fmt.Errorf("node %q: ssh transport requires addr", node)
				}
				if strings.TrimSpace(sp.User) == "" {
					sp.User = "admin" // sonic-vm guests: admin/admin via vrnetlab
				}
			}
			cfg.specs[node] = sp
		}
	}

	if cfg.anySSH() {
		var err error
		if cfg.sshKey, err = require0600(getenv, "FABRIC_SSH_KEY"); err != nil {
			return cfg, err
		}
		if cfg.knownHosts, err = require0600(getenv, "FABRIC_SSH_KNOWN_HOSTS"); err != nil {
			return cfg, err
		}
	}
	return cfg, nil
}

// require0600 returns the env var's path, refusing when unset/missing or when
// group/other hold any permission (the private key and host keys are the lab's
// credentials: nothing wider than owner-only).
func require0600(getenv func(string) string, envName string) (string, error) {
	p := strings.TrimSpace(getenv(envName))
	if p == "" {
		return "", fmt.Errorf("%s is required when any node uses the ssh transport", envName)
	}
	fi, err := os.Stat(p)
	if err != nil {
		return "", fmt.Errorf("%s (%s): %w", envName, p, err)
	}
	if fi.IsDir() {
		return "", fmt.Errorf("%s (%s) is a directory", envName, p)
	}
	if perm := fi.Mode().Perm(); perm&0o077 != 0 {
		return "", fmt.Errorf("%s (%s) must have mode 0600, got %o", envName, p, perm)
	}
	return p, nil
}
