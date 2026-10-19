#!/usr/bin/env bash
# Re-record evpn3, evpn2, steering groups in canonical order (rollback last).
cd /root/agentic-netops || exit 9
for spec in \
  "spike-evpn3-state-leaf01|bash scripts/spike/evpn3-state.sh leaf01" \
  "spike-evpn3-state-leaf02|bash scripts/spike/evpn3-state.sh leaf02" \
  "spike-evpn3-ping|bash scripts/spike/evpn3-ping.sh" \
  "spike-evpn3-capture|bash scripts/spike/evpn3-capture.sh" \
  "spike-evpn3-kl006|bash scripts/spike/evpn3-kl006.sh" \
  "spike-evpn3-rollback|bash scripts/spike/evpn3-rollback.sh" \
  "spike-evpn2-state-leaf01|bash scripts/spike/evpn2-state.sh leaf01" \
  "spike-evpn2-state-leaf02|bash scripts/spike/evpn2-state.sh leaf02" \
  "spike-evpn2-ping|bash scripts/spike/evpn2-ping.sh" \
  "spike-evpn2-capture|bash scripts/spike/evpn2-capture.sh" \
  "spike-evpn2-rollback|bash scripts/spike/evpn2-rollback.sh" \
  "spike-steering-path|bash scripts/spike/steering-path.sh" \
  "spike-steering-failover-launcher|bash scripts/spike/steering-failover.sh launcher" \
  "spike-steering-failover-guest-if|bash scripts/spike/steering-failover.sh guest" \
  "spike-steering-failover-bgp|bash scripts/spike/steering-failover.sh bgp" \
  "spike-steering-return|bash scripts/spike/steering-failover.sh return" \
; do
  name=${spec%%|*}; cmd=${spec#*|}
  echo "##### RECORD $name -- $cmd"
  scripts/proof.sh "$name" -- $cmd
  echo "##### RC-$name=$?"
done
echo "REST-RERECORD-DONE"
