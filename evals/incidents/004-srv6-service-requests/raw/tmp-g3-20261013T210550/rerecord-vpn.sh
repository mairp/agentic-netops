#!/usr/bin/env bash
# Re-record the spike-vpn group in canonical group order (rollback last).
cd /root/agentic-netops || exit 9
for spec in \
  "spike-vpn-state-leaf01|scripts/spike/vrf-apply.sh leaf01" \
  "spike-vpn-state-leaf02|scripts/spike/vrf-apply.sh leaf02" \
  "spike-vpn-ping|scripts/spike/vpn-ping.sh" \
  "spike-vpn-capture|scripts/spike/vpn-capture.sh" \
  "spike-vpn-readback-leaf01|bash scripts/spike/vpn-readback.sh leaf01" \
  "spike-vpn-readback-leaf02|bash scripts/spike/vpn-readback.sh leaf02" \
  "spike-vpn-clients|bash scripts/spike/vpn-clients.sh" \
  "spike-vpn-rollback|bash scripts/spike/vpn-rollback.sh" \
; do
  name=${spec%%|*}; cmd=${spec#*|}
  echo "##### RECORD $name -- $cmd"
  scripts/proof.sh "$name" -- $cmd
  echo "##### RC-$name=$?"
done
echo "VPN-RERECORD-DONE"
