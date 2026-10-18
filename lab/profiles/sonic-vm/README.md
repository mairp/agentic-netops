# SONiC VM Conformance Overlay

Profile: sonic-vm

This overlay enables the full conformance profile for SONiC running with hardware emulation
that requires KVM and nested virtualization support on the host.

Requirements:
- Nested virtualization enabled in the host BIOS and hypervisor
- /dev/kvm available to containers (privileged Docker runtime)
- CPU: >= 8 cores; Memory: >= 16 GB; Disk: >= 40 GB free
- Docker runtime with `--device /dev/kvm` support

Notes:
- The sonic-vm image is pinned by digest in versions.lock.yaml and must be imported locally.
- This profile may take significantly longer to boot than sonic-vs.
- The bootstrap drives the guest over **ssh** (vrnetlab launcher, admin on the
  launcher's mgmt IP): TLS + gNMI enablement, the fabric baseline, and
  persistence. Southbound SERVICE writes do not go over gNMI — the fabric
  executor renders them as GCU patches over ssh (T565/T576 transport); gNMI
  serves reads (and the qualification gate's read-back witnesses).
- The full qualification gate (`scripts/lib/qualify.sh`) passes on this profile
  with 17 passed / 0 failed / 0 skipped (proofs `q14-gate-vm`/`q14-report-vm`).
  Verified facts that replace two stale claims:
  - The guest kernel (SONiC Debian 6.1) DOES include kernel seg6 lwtunnel.
    The earlier "seg6 absent" reading came from probing with a route bound to
    `dev lo`, which the kernel silently drops; the suite's probe binds
    `Loopback0` and the seg6 probe self-test passes here. SRv6 dataplane
    witnesses run on this profile.
  - Node identity is bootstrap-owned per `lab/profiles/sonic-vm/fabric.yaml`:
    spines AS 65000, leaf01 65101, leaf02 65102; loopbacks
    `10.0.0.<11,12,21,22>` (leaf01 `Loopback0 10.0.0.21/32`); each node's
    router-id is its IPv4 loopback. The image's factory identity (every node
    `Loopback0=10.1.0.1/32`, bgpd AS 65100) does not survive provisioning:

    ```bash verify="local AS number 65101"
    ssh -i secrets/fabric-executor.key -o UserKnownHostsFile=secrets/known_hosts_executor \
      admin@172.31.0.21 "vtysh -c 'show bgp summary'"
    ```
- Persistence is verified with a guest `config reload` (re-reads
  `/etc/sonic/config_db.json`) rather than a container restart.

Known exceptions:
- The topology (`lab/topology.sonic-vm.clab.yml`) names the sonic-vm image by
  TAG (`local/sonic-vm:202505`) instead of the one-form
  `local/sonic-vm@sha256:<digest>` pin in versions.lock.yaml. Why: containerlab
  cannot resolve a local image by digest without a registry — proof
  `p1-image-by-digest` shows containerlab 0.79 normalizes `name@sha256:<digest>`
  to a registry reference (`docker.io/local/...`) and pulls (and plain docker
  behaves the same for an imported image, which carries no repository digest).
  Guard: `scripts/provision.sh` asserts, before every sonic-vm bring-up, that
  the tagged image's ID equals the pinned digest and fails the bring-up
  otherwise (with a warning that this exception is in effect). Remediation
  plan: serve the image from a local registry so the topology can name the
  digest directly, then remove the exception and the warning.
