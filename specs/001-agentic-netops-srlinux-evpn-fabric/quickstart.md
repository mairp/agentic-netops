# Quickstart

```bash
# host tooling + pins (Docker, kind, containerlab, gnmic, kubectl, helm, yq)
./scripts/install-deps.sh
docker pull ghcr.io/nokia/srlinux:26.7.2

# fabric + control plane (~15-25 min first run)
./scripts/provision.sh --profile srlinux --cluster-name agentic-netops
make lab-qualify
./tests/integration/fabric_verify.sh

# intent tier
cp .env.example .env && $EDITOR .env
./scripts/provision.sh --profile srlinux --cluster-name agentic-netops --with-intent-tier
# console: http://localhost:30000

# proofs on a leaf (read-only)
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance summary"
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance default protocols bgp neighbor"

# teardown
./scripts/off.sh --delete-kind true
```
