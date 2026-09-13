# SR Linux profile — bootstrap

Scope: **identity and trust only.** The underlay (dual-stack eBGP), the overlay
(EVPN over iBGP with spine route reflectors) and the bootstrap tenants
(`vlan100` mac-vrf, `VrfBlue` ip-vrf) all come up from the per-node
`startup-config` files in `../config/`, applied by containerlab at deploy time.
Nothing here configures routing, and there is no post-boot shell hook on any
node.

This directory therefore carries no scripts. The three steps below are
implemented in `scripts/lib/containerlab.sh bootstrap srlinux`, because they
need the cluster (to read the generated credentials) and the host (to read the
containerlab CA), not the node.

## What bootstrap does

1. **Wait for gNMI.** Poll `Capabilities` on `<mgmt-ip>:57400` for every node
   over TLS with the containerlab CA, using the image default admin credentials.
   A node that never answers fails the step — the lab is not usable without a
   gNMI endpoint, and pretending otherwise would hide the defect.

2. **Create the generated user.** One gNMI `Set` per node against
   `/system/aaa/authentication/user[username=agentic]` with the password from
   Secret `gnmi-lab-creds`. Idempotent: a node that already carries the user is
   skipped (the marker is the user itself, read back over gNMI — not a file, so
   a re-created container cannot fake it).

3. **Publish the CA.** Copy `lab/clab-agentic-netops-fabric/.tls/ca/ca.pem` into
   Secret `gnmi-lab-tls` under key `ca.crt`, patching the existing Secret. The
   executor, gnmic and every qualification suite trust that one CA.

## Credentials

The SR Linux image default admin password is read **only** from the environment
variable `SRLINUX_ADMIN_PASSWORD` (default `NokiaSrl1!`) and used exactly once
per node, to create the generated user. It is never written to a file, a
Kubernetes Secret, this repository or a log line (FR-016). Everything afterwards
— the executor, gnmic, the suites — authenticates as `agentic` with the
per-lab generated password.

The SR Linux gNMI server does not require a client certificate. `tls.crt` and
`tls.key` stay in `gnmi-lab-tls` for API compatibility with the existing secret
generator, and clients present `ca.crt` only.

## Persistence

There is no named volume and no persisted `/etc` mount. A node keeps its running
configuration across `docker restart`, and `containerlab deploy --reconfigure`
re-applies the startup-config, so there is exactly one source for node state in
the tree. `scripts/lib/persistence.sh` proves the restart case with a witness
leaf written over gNMI, saved, and re-read after the restart.
