// SPDX-License-Identifier: Apache-2.0

// Package render holds the OpenConfig/native path scaffolds from the original
// SDC-based design. IT IS NOT THE SOUTHBOUND WRITE PATH.
//
// On this fabric the only write path to a device is the fabric-executor's gNMI
// Set, driven by the deterministic renderer in pkg/fabricplan, and the register
// that guards it is pkg/register/oc_vs_srlinux.yaml. Nothing in this package
// reaches a node: the paths below were written for the pinned SONiC image's
// model and are kept for the SDC Config shapes and the unit tests that pin
// them, not because a node ever sees them.
//
// The SRv6 renderers in particular describe a capability this site does not
// have: the SR Linux 7220 container has no SRv6 data plane, `fabric-compat-pins`
// declares `cap-sai-srv6: "false"`, and controllers/srv6service reports
// `Ready=False` / `CapabilityMissing` on every SRv6Service rather than
// rendering anything. See api/v1alpha1/srv6service_types.go.
package render
