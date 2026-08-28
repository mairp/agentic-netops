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
