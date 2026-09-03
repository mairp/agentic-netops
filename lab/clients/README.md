# Linux Client Images and Deterministic Addressing

Deterministic dual-stack addressing plan for containerlab endpoints:

- client01 (leaf01 attachment)
  - eth1: 192.0.2.11/31 <-> leaf01:eth3 192.0.2.10/31
  - eth1: 2001:db8:1::11/127 <-> leaf01:eth3 2001:db8:1::10/127
- client02 (leaf02 attachment)
  - eth1: 192.0.2.21/31 <-> leaf02:eth3 192.0.2.20/31
  - eth1: 2001:db8:2::21/127 <-> leaf02:eth3 2001:db8:2::20/127
- srv6-client01 (leaf01 attachment)
  - eth1: 192.0.2.31/31 <-> leaf01:eth4 192.0.2.30/31
  - eth1: 2001:db8:3::31/127 <-> leaf01:eth4 2001:db8:3::30/127
- srv6-client02 (leaf02 attachment)
  - eth1: 192.0.2.41/31 <-> leaf02:eth4 192.0.2.40/31
  - eth1: 2001:db8:4::41/127 <-> leaf02:eth4 2001:db8:4::40/127

Images:
- ghcr.io/agentic-netops/linux-net (pinned by digest in topology.clab.yml) with iproute2, ping, curl, tcpdump
- ghcr.io/agentic-netops/linux-srv6 (pinned below) with iproute2 SRv6 tools

Pinned digests (example placeholders, must match versions.lock.yaml if added there):
- linux-net: sha256:4444... (see topology.clab.yml)
- linux-srv6: sha256:5555...
