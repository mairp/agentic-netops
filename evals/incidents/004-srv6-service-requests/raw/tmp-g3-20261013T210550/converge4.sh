#!/usr/bin/env bash
# Pass-15 convergence: rebuild the spike state (identity/underlay/kernel/locators)
# on the re-provisioned lab, then probe each node.
cd /root/agentic-netops || exit 9
source scripts/spike/spike-env.sh
source scripts/spike/ensure-fabric.sh || exit 8
ensure_fabric
echo "=== probes after converge4 ==="
for n in leaf01 leaf02 spine01 spine02; do
  c=$(container_of "$n")
  p=$(_ensure_fabric_probe "$n" | tail -1)
  echo "$n: $p"
done
