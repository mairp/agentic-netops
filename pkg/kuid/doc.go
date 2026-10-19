// SPDX-License-Identifier: Apache-2.0
// Package kuid is the Go KUID claim client consumed by the SRv6Service
// controller (spec 004, US3). It claims per-service identifiers from the
// pools of data-model.md §8.1 through the served `*.be.kuid.dev` groups of
// the pinned kuid-server, waits for the allocated value, and releases every
// claim carrying a correlation id.
//
// It deliberately mirrors the tier's Python client
// (agents/provisioning/allocator/kuid.py): claims live in namespace
// `kuid-system`, are stamped with `agentic-netops.io/correlation-id` before
// any wait, report the allocated integer in `status.id` of the
// `*.be.kuid.dev` claims, and — because the pinned kuid-server's GENID
// family is broken at runtime (tier finding, research.md Decision 11) —
// GENID-family failures trigger a Kubernetes Lease fallback whose create is
// still atomic and cluster-authoritative. This package does not invent
// identifiers locally and never claims locators: those are bootstrap-owned
// (data-model.md §4).
package kuid
