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
- The bootstrap remains limited to TLS + gNMI enablement and persistence; the EVPN/SRv6 tests
  program configuration via gNMI during qualification.
- The full qualification gate (`scripts/lib/qualify.sh`) passes on this profile
  (17/17). Verified caveats: the guest kernel has no seg6 lwtunnel (kernel-side
  `encap seg6` dataplane witnesses auto-skip; SRv6 control plane is asserted over
  gNMI), the image default config gives every node `Loopback0=10.1.0.1/32` and
  bgpd AS 65100/router-id 10.1.0.1 (do not use 10.1.0.1 as a peer address), and
  persistence is verified with a guest `config reload`.
