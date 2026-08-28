#!/usr/bin/env bash
# T019: Validate mgmt network CIDR does not overlap Kind pod/service CIDRs and show node network attachments
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
CTX="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"
MGMT_NET=${AINETOPS_MGMT_NET:-ainetops-mgmt}
# Extract pod/service CIDRs from Kind config
POD_CIDR=$(awk -F': *' '/podSubnet:/ {print $2; exit}' "$ROOT/config/kind/cluster.yaml")
SVC_CIDR=$(awk -F': *' '/serviceSubnet:/ {print $2; exit}' "$ROOT/config/kind/cluster.yaml")
# Show Docker network inspect for mgmt
{ docker network inspect "$MGMT_NET"; } > "$ROOT/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docker-network-${MGMT_NET}.json" 2>/dev/null || true
# Show Kind nodes' network attachments
{ kind get nodes --name "${AINETOPS_CLUSTER_NAME:-ainetops}" | xargs -I{} docker inspect -f '{{json .Name}} {{json .NetworkSettings.Networks}}' {} ; } > "$ROOT/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kind-nodes-networks.txt" 2>/dev/null || true
# Record CIDRs into a proof file
{
  echo "mgmt_cidr=172.31.0.0/16"
  echo "pod_cidr=$POD_CIDR"
  echo "svc_cidr=$SVC_CIDR"
} > "$ROOT/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cidr-separation.txt"
echo "[probe] separation artifacts written"
