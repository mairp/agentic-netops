//go:build !agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// probe_stub.go — link stub for the tag-free build.
//
// probe.go is deliberately tag-free so probe_test.go runs in a plain
// `go test` (its pure half is tested without the k8s tag). That makes the
// package buildable without agentic_netops_k8s, and package main then needs
// a main to link. This stub only exists in that no-tag build; the real
// main() in main.go replaces it whenever the tag is set. It never runs.
package main

func main() {}
