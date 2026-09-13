# Lab Bootstrap Overview

This directory documents the bootstrap content shared by the lab profile and the
endpoint images.

- The fabric nodes are Nokia SR Linux (`nokia_srlinux`, type `ixrd2l`). Their
  underlay, overlay and bootstrap tenants come from per-node startup
  configuration in `lab/profiles/srlinux/config/*.cfg`, applied by containerlab
  at deploy time — no post-boot shell hook runs on any node.
- The remaining bootstrap is identity and trust only: wait for gNMI on
  `<mgmt-ip>:57400`, create the generated `agentic` user over gNMI, and publish
  the containerlab CA into Secret `gnmi-lab-tls`. It is implemented in
  `scripts/lib/containerlab.sh bootstrap srlinux` and described in
  `lab/profiles/srlinux/bootstrap/README.md`.
- Endpoint Linux images derive deterministic addressing via containerlab `links`
  and per-node `exec` statements in `lab/topology.clab.yml`.
