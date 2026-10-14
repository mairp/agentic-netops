#!/usr/bin/env bash
# chain2.sh — pass-18 detached chain. Sequence:
#   P  FRESH PROVISION (./scripts/provision.sh --profile sonic-vm): the
#      leaf02 orchagent wedge of 2026-10-13 04:1x survives every GCU
#      re-write (CONFIG_DB rows land, APPL_DB is never consumed, kernel is
#      never programmed); a full re-provision is the only known-clean reset
#      (T104, rc=0 on 2026-10-12). A qualify-gate rc=1 (EVPN-Type2 race,
#      2 of the last 4 deploys) is tolerated — the LAB is what matters.
#   Q  converge + orchagent canary: BOTH leaves must program a VRF through
#      the GCU write path (hardened vrf-apply.sh, 3 silent retries) before
#      any recording; otherwise abort — never record a sick lab again.
#   A  seed state, baseline re-record x4, dry replay (one bounded re-record
#      retry on differ).
#   B  converge bootstrap probe.
#   C  vpn group re-record x8 (canonical order) + T106 receipt.
#   D  steering group re-record x5 + T107 receipt.
#   E/F evpn3 + evpn2 receipts (T108/T109).
#   G  seed restore + baseline receipt (T105).
# Every step logs to /tmp/g3/<step>.log, rc to /tmp/g3/<step>.rc.
# Summary -> /tmp/g3/chain2.summary, completion marker -> /tmp/g3/chain2.done.
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

abort() { # abort <reason>
  log "ABORT: $1"
  { echo "ABORT: $1"; echo "at $(date +%H:%M:%S)"; } > /tmp/g3/chain2.summary
  echo "CHAIN2-DONE(aborted) $(date +%H:%M:%S)" > /tmp/g3/chain2.done
  exit 1
}

conv_probe='bash -c ". scripts/spike/spike-env.sh; . scripts/spike/ensure-fabric.sh; ensure_fabric; for n in leaf01 leaf02 spine01 spine02; do echo \"\$n: \$( _ensure_fabric_probe \"\$n\" | tail -1)\"; done"'

# ---- PHASE P: fresh provision -------------------------------------------------
rm -f /tmp/g3/chain2.done /tmp/g3/chain2.summary
step P-provision ./scripts/provision.sh --profile sonic-vm
up=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^clab-agentic-netops-fabric-')
[ "${up:-0}" -ge 8 ] || abort "lab down after provision (containers up=$up, provision rc=$(cat /tmp/g3/P-provision.rc))"
log "PHASE P done: lab_up=$up provision.rc=$(cat /tmp/g3/P-provision.rc); settling 90s"
sleep 90

# ---- PHASE Q: converge + orchagent canary ------------------------------------
step Q-converge eval "$conv_probe"
if grep -q 'H-OK=0' /tmp/g3/Q-converge.log 2>/dev/null; then
  sleep 120
  step Q-converge2 eval "$conv_probe"
  grep -q 'H-OK=0' /tmp/g3/Q-converge2.log 2>/dev/null && abort "converge incomplete: $(grep 'H-OK=0' /tmp/g3/Q-converge2.log | head -2 | tr '\n' ' ')"
fi
step Q-canary bash -c 'bash scripts/spike/vrf-apply.sh leaf01 >/dev/null 2>&1 && bash scripts/spike/vrf-apply.sh leaf02 >/dev/null 2>&1'
[ "$(cat /tmp/g3/Q-canary.rc 2>/dev/null)" = 0 ] || abort "orchagent canary failed: a leaf cannot program a VRF even after a fresh provision (see /tmp/g3/Q-canary.log)"
log "PHASE Q done: converge + canary OK"

# ---- PHASE A: seed state, baseline re-record (T040-T043), dry check ----------
step A-seed bash scripts/spike/seed-restore.sh
step A-b-spine01 scripts/proof.sh spike-baseline-spine01 -- scripts/spike/baseline-capture.sh spine01
step A-b-spine02 scripts/proof.sh spike-baseline-spine02 -- scripts/spike/baseline-capture.sh spine02
step A-b-leaf01  scripts/proof.sh spike-baseline-leaf01  -- scripts/spike/baseline-capture.sh leaf01
step A-b-leaf02  scripts/proof.sh spike-baseline-leaf02  -- scripts/spike/baseline-capture.sh leaf02
step A-dry       scripts/proof.sh replay spike-baseline
if [ "$(cat /tmp/g3/A-dry.rc 2>/dev/null)" != "0" ]; then
  log "A-dry differs — one bounded baseline re-record"
  for n in spine01 spine02 leaf01 leaf02; do
    step "A-b2-$n" scripts/proof.sh "spike-baseline-$n" -- scripts/spike/baseline-capture.sh "$n"
  done
  step A-dry scripts/proof.sh replay spike-baseline
fi
log "PHASE A done (dry=$(cat /tmp/g3/A-dry.rc 2>/dev/null))"

# ---- PHASE B: converge the bootstrap for the service groups ------------------
step B-converge eval "$conv_probe"
grep -q 'H-OK=0' /tmp/g3/B-converge.log 2>/dev/null && abort "service-group converge incomplete: $(grep 'H-OK=0' /tmp/g3/B-converge.log | head -2 | tr '\n' ' ')"
log "PHASE B done"

# ---- PHASE C: vpn group re-record x8 (canonical order) + receipt -------------
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

# ---- PHASE D: steering group re-record x5 (canonical order) + receipt --------
step D-1 scripts/proof.sh spike-steering-path              -- bash scripts/spike/steering-path.sh
step D-2 scripts/proof.sh spike-steering-failover-launcher -- bash scripts/spike/steering-failover.sh launcher
step D-3 scripts/proof.sh spike-steering-failover-guest-if -- bash scripts/spike/steering-failover.sh guest
step D-4 scripts/proof.sh spike-steering-failover-bgp      -- bash scripts/spike/steering-failover.sh bgp
step D-5 scripts/proof.sh spike-steering-return            -- bash scripts/spike/steering-failover.sh return
receipt spike-rerun-steering spike-steering
log "PHASE D done"

# ---- PHASE E/F: evpn receipts -------------------------------------------------
receipt spike-rerun-evpn3 spike-evpn3
receipt spike-rerun-evpn2 spike-evpn2
log "PHASE E/F done"

# ---- PHASE G: back to seed, then the baseline receipt -------------------------
step G-seed bash scripts/spike/seed-restore.sh
receipt spike-rerun-baseline spike-baseline
log "PHASE G done"

{
  echo "P-provision=$(cat /tmp/g3/P-provision.rc 2>/dev/null)"
  echo "Q-converge=$(cat /tmp/g3/Q-converge.rc 2>/dev/null)"
  echo "Q-canary=$(cat /tmp/g3/Q-canary.rc 2>/dev/null)"
  echo "A-seed=$(cat /tmp/g3/A-seed.rc 2>/dev/null)"
  echo "A-dry=$(cat /tmp/g3/A-dry.rc 2>/dev/null)"
  echo "B-converge=$(cat /tmp/g3/B-converge.rc 2>/dev/null)"
  for r in spike-rerun-vpn spike-rerun-steering spike-rerun-evpn3 spike-rerun-evpn2 spike-rerun-baseline; do
    echo "$r=$(cat "/tmp/g3/$r.verdict" 2>/dev/null || echo missing)"
  done
} > /tmp/g3/chain2.summary 2>&1
echo "CHAIN2-DONE $(date +%H:%M:%S)" > /tmp/g3/chain2.done
log "CHAIN2 DONE — summary in /tmp/g3/chain2.summary"
