//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// config_test.go — transport configuration parsing (T148): every refusal case
// from contracts/executor-transport.md §2, plus the docker default for a node
// absent from FABRIC_NODE_TRANSPORT.
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func getenvOf(env map[string]string) func(string) string {
	return func(k string) string { return env[k] }
}

func writeKeyFile(t *testing.T, dir, name string, perm os.FileMode) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("material"), perm); err != nil {
		t.Fatalf("write %s: %v", p, err)
	}
	return p
}

// TestConfigDefaultsToDocker: a node absent from FABRIC_NODE_TRANSPORT uses
// the docker transport and requires no key material.
func TestConfigDefaultsToDocker(t *testing.T) {
	cfg, err := loadTransportConfig(getenvOf(map[string]string{
		"FABRIC_NODE_MAP": `{"leaf01":"clab-x-leaf01"}`,
	}))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.anySSH() {
		t.Fatal("no ssh nodes declared, anySSH() = true")
	}
}

// TestConfigNodeInOneMapNotOther: a FABRIC_NODE_TRANSPORT entry whose node is
// not in FABRIC_NODE_MAP is refused, naming the node.
func TestConfigNodeInOneMapNotOther(t *testing.T) {
	dir := t.TempDir()
	key := writeKeyFile(t, dir, "k", 0o600)
	_, err := loadTransportConfig(getenvOf(map[string]string{
		"FABRIC_NODE_MAP":        `{"leaf01":"clab-x-leaf01"}`,
		"FABRIC_NODE_TRANSPORT":  `{"spine01":{"kind":"ssh","addr":"172.31.0.11","user":"admin"}}`,
		"FABRIC_SSH_KEY":         key,
		"FABRIC_SSH_KNOWN_HOSTS": writeKeyFile(t, dir, "kh", 0o600),
	}))
	if err == nil || !strings.Contains(err.Error(), "spine01") {
		t.Fatalf("want error naming spine01, got %v", err)
	}
}

// TestConfigUnknownKind: an unknown transport kind is refused, naming the
// node and the kind.
func TestConfigUnknownKind(t *testing.T) {
	_, err := loadTransportConfig(getenvOf(map[string]string{
		"FABRIC_NODE_MAP":       `{"leaf01":"clab-x-leaf01"}`,
		"FABRIC_NODE_TRANSPORT": `{"leaf01":{"kind":"telnet","addr":"172.31.0.21","user":"admin"}}`,
	}))
	if err == nil || !strings.Contains(err.Error(), "telnet") || !strings.Contains(err.Error(), "leaf01") {
		t.Fatalf("want error naming leaf01 and telnet, got %v", err)
	}
}

// TestConfigMissingKey: an ssh node with no FABRIC_SSH_KEY is refused.
func TestConfigMissingKey(t *testing.T) {
	_, err := loadTransportConfig(getenvOf(map[string]string{
		"FABRIC_NODE_MAP":       `{"leaf01":"clab-x-leaf01"}`,
		"FABRIC_NODE_TRANSPORT": `{"leaf01":{"kind":"ssh","addr":"172.31.0.21","user":"admin"}}`,
	}))
	if err == nil || !strings.Contains(err.Error(), "FABRIC_SSH_KEY") {
		t.Fatalf("want error mentioning FABRIC_SSH_KEY, got %v", err)
	}
}

// TestConfigKeyWiderThan0600: the private key must not be readable by group
// or others (contract §2: "wider permissions than 0600").
func TestConfigKeyWiderThan0600(t *testing.T) {
	dir := t.TempDir()
	_, err := loadTransportConfig(getenvOf(map[string]string{
		"FABRIC_NODE_MAP":        `{"leaf01":"clab-x-leaf01"}`,
		"FABRIC_NODE_TRANSPORT":  `{"leaf01":{"kind":"ssh","addr":"172.31.0.21","user":"admin"}}`,
		"FABRIC_SSH_KEY":         writeKeyFile(t, dir, "k", 0o644),
		"FABRIC_SSH_KNOWN_HOSTS": writeKeyFile(t, dir, "kh", 0o600),
	}))
	if err == nil || !strings.Contains(err.Error(), "0600") {
		t.Fatalf("want 0600 permission error, got %v", err)
	}
	// Missing known-hosts file is refused too.
	_, err = loadTransportConfig(getenvOf(map[string]string{
		"FABRIC_NODE_MAP":       `{"leaf01":"clab-x-leaf01"}`,
		"FABRIC_NODE_TRANSPORT": `{"leaf01":{"kind":"ssh","addr":"172.31.0.21","user":"admin"}}`,
		"FABRIC_SSH_KEY":        writeKeyFile(t, dir, "k2", 0o600),
	}))
	if err == nil || !strings.Contains(err.Error(), "FABRIC_SSH_KNOWN_HOSTS") {
		t.Fatalf("want error mentioning FABRIC_SSH_KNOWN_HOSTS, got %v", err)
	}
}

// TestConfigKnownHostsWiderThan0600.
func TestConfigKnownHostsWiderThan0600(t *testing.T) {
	dir := t.TempDir()
	_, err := loadTransportConfig(getenvOf(map[string]string{
		"FABRIC_NODE_MAP":        `{"leaf01":"clab-x-leaf01"}`,
		"FABRIC_NODE_TRANSPORT":  `{"leaf01":{"kind":"ssh","addr":"172.31.0.21","user":"admin"}}`,
		"FABRIC_SSH_KEY":         writeKeyFile(t, dir, "k", 0o600),
		"FABRIC_SSH_KNOWN_HOSTS": writeKeyFile(t, dir, "kh", 0o664),
	}))
	if err == nil || !strings.Contains(err.Error(), "0600") {
		t.Fatalf("want 0600 permission error, got %v", err)
	}
}

// TestConfigValidSSH: a valid ssh declaration parses; the spec round-trips
// with defaults applied (user defaults to admin).
func TestConfigValidSSH(t *testing.T) {
	dir := t.TempDir()
	cfg, err := loadTransportConfig(getenvOf(map[string]string{
		"FABRIC_NODE_MAP":        `{"leaf01":"clab-x-leaf01"}`,
		"FABRIC_NODE_TRANSPORT":  `{"leaf01":{"kind":"ssh","addr":"172.31.0.21","user":"admin"}}`,
		"FABRIC_SSH_KEY":         writeKeyFile(t, dir, "k", 0o600),
		"FABRIC_SSH_KNOWN_HOSTS": writeKeyFile(t, dir, "kh", 0o600),
	}))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	spec, ok := cfg.spec("leaf01")
	if !ok || spec.Kind != "ssh" || spec.Addr != "172.31.0.21" || spec.User != "admin" {
		t.Fatalf("spec = %+v ok=%v", spec, ok)
	}
	if !cfg.anySSH() {
		t.Fatal("anySSH() = false with an ssh node declared")
	}
}
