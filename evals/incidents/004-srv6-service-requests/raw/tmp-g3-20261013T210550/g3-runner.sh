#!/usr/bin/env bash
# g3-runner.sh — pass-17 detached chain (pass 17, 2025-10-13 ~04:0x):
# after hw-identity normalization (addr_norm masks fe80::/fec0:: EUI-64
# prefixes + MACs), re-record every replay group that carried volatile bytes,
# in canonical .record-order, then record the five T105-T109 receipts.
# Fail-fast WITHIN a group's re-record sequence, continue ACROSS groups;
# every step logs to /tmp/g3/<step>.log, rc to /tmp/g3/<step>.rc.
# receipts verdict: clean (no ^differ: lines in the receipt .out) | differ.
set -u
cd /root/agentic-netops || exit 9
P=.wiggum/features/004-srv6-service-requests/gates/proofs
log() { echo "##### $(date +%H:%M:%S) $*"; }

step() { # step <name> <argv...>
  local n=$1; shift
  log "START $n: $*"
  "$@" > "/tmp/g3/$n.log" 2>&1
  echo $? > "/tmp/g3/$n.rc"
  log "RC $n=$(cat /tmp/g3/$n.rc)"
}

receipt() { # receipt <name> <group-prefix>
  local n=$1 g=$2
  step "$n" scripts/proof.sh "$n" -- scripts/proof.sh replay "$g"
  if grep -q '^differ:' "$P/$n.out" 2>/dev/null; then
    echo differ > "/tmp/g3/$n.verdict"
  else
    echo clean > "/tmp/g3/$n.verdict"
  fi
  log "RECEIPT $n verdict=$(cat "/tmp/g3/$n.verdict")"
}

# ---- PHASE A: seed state, baseline re-record (T040-T043), dry check ----
step A-seed  bash scripts/spike/seed-restore.sh
step A-b-spine01 scripts/proof.sh spike-baseline-spine01 -- scripts/spike/baseline-capture.sh spine01
step A-b-spine02 scripts/proof.sh spike-baseline-spine02 -- scripts/spike/baseline-capture.sh spine02
step A-b-leaf01  scripts/proof.sh spike-baseline-leaf01  -- scripts/spike/baseline-capture.sh leaf01
step A-b-leaf02  scripts/proof.sh spike-baseline-leaf02  -- scripts/spike/baseline-capture.sh leaf02
step A-dry       scripts/proof.sh replay spike-baseline
log "PHASE A done (seed=$([ -f /tmp/g3/A-seed.rc ] && cat /tmp/g3/A-seed.rc) dry=$(cat /tmp/g3/A-dry.rc 2>/dev/null))"

# ---- PHASE B: converge the bootstrap for the service groups ----
step B-converge bash -c '. scripts/spike/spike-env.sh; . scripts/spike/ensure-fabric.sh; ensure_fabric; for n in leaf01 leaf02 spine01 spine02; do echo "$n: $(_ensure_fabric_probe "$n" | tail -1)"; done'
grep -q 'H-OK=0' /tmp/g3/B-converge.log 2>/dev/null && echo 1 > /tmp/g3/B-converge.rc || echo 0 > /tmp/g3/B-converge.rc
log "PHASE B done converge.rc=$(cat /tmp/g3/B-converge.rc)"

# ---- PHASE C: vpn group re-record x8 (canonical order) + receipt ----
step C-1 scripts/proof.sh spike-vpn-state-leaf01   -- scripts/spike/vrf-apply.sh leaf01
step C-2 scripts/proof.sh spike-vpn-state-leaf02   -- scripts/spike/vrf-apply.sh leaf02
step C-3 scripts/proof.sh spike-vpn-ping           -- scripts/spike/vpn-ping.sh
step C-4 scripts/proof.sh spike-vpn-capture        -- scripts/spike/vpn-capture.sh
step C-5 scripts/proof.sh spike-vpn-readback-leaf01 -- bash scripts/spike/vpn-readback.sh leaf01
step C-6 scripts/proof.sh spike-vpn-readback-leaf02 -- bash scripts/spike/vpn-readback.sh leaf02
step C-7 scripts/proof.sh spike-vpn-clients        -- bash scripts/spike/vpn-clients.sh
step C-8 scripts/proof.sh spike-vpn-rollback       -- bash scripts/spike/vpn-rollback.sh
receipt spike-rerun-vpn spike-vpn
log "PHASE C done"

# ---- PHASE D: steering group re-record x5 (canonical order) + receipt ----
step D-1 scripts/proof.sh spike-steering-path              -- bash scripts/spike/steering-path.sh
step D-2 scripts/proof.sh spike-steering-failover-launcher -- bash scripts/spike/steering-failover.sh launcher
step D-3 scripts/proof.sh spike-steering-failover-guest-if -- bash scripts/spike/steering-failover.sh guest
step D-4 scripts/proof.sh spike-steering-failover-bgp      -- bash scripts/spike/steering-failover.sh bgp
step D-5 scripts/proof.sh spike-steering-return            -- bash scripts/spike/steering-failover.sh return
receipt spike-rerun-steering spike-steering
log "PHASE D done"

# ---- PHASE E/F: evpn receipts (stored outs carry no volatile bytes; only
# re-record those groups later if these receipts actually differ) ----
receipt spike-rerun-evpn3 spike-evpn3
receipt spike-rerun-evpn2 spike-evpn2
log "PHASE E/F done"

# ---- PHASE G: back to seed, then the baseline receipt ----
step G-seed bash scripts/spike/seed-restore.sh
receipt spike-rerun-baseline spike-baseline
log "PHASE G done"

{
  echo "A-seed=$(cat /tmp/g3/A-seed.rc 2>/dev/null)"
  echo "A-dry=$(cat /tmp/g3/A-dry.rc 2>/dev/null)"
  echo "B-converge=$(cat /tmp/g3/B-converge.rc 2>/dev/null)"
  for r in spike-rerun-vpn spike-rerun-steering spike-rerun-evpn3 spike-rerun-evpn2 spike-rerun-baseline; do
    echo "$r=$(cat "/tmp/g3/$r.verdict" 2>/dev/null || echo missing)"
  done
} > /tmp/g3/runner.summary 2>&1
echo "RUNNER-DONE $(date +%H:%M:%S)" > /tmp/g3/runner.done
log "RUNNER DONE — summary in /tmp/g3/runner.summary"
