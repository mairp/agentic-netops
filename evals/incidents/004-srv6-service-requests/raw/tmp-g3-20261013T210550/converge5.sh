#!/usr/bin/env bash
cd /root/agentic-netops || exit 9
source scripts/spike/spike-env.sh
source scripts/spike/ensure-fabric.sh
echo "=== ensure_fabric start $(date +%H:%M:%S) ==="
ensure_fabric
echo "=== ensure_fabric done $(date +%H:%M:%S) ==="
ok=1
for n in leaf01 leaf02 spine01 spine02; do
  r=$(_ensure_fabric_probe "$n" | tail -1)
  echo "$n: $r"
  [ "$r" = "H-OK=1" ] || ok=0
done
echo "CONVERGE5-RC=$ok"
exit $ok
