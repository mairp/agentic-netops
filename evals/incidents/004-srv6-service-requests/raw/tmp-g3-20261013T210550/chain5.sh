#!/usr/bin/env bash
# chain5.sh — clean relaunch after chain4 was killed at 14:12 (poisoned phase A).
# What happened to chain4 (measured, /tmp/g3/chain4.log 14:05-14:08):
#   scripts/spike/seed-restore.sh stage 1 removed /VRF BEFORE /INTERFACE, but the
#   service attachment row INTERFACE|Ethernet12|... carries vrf_name=Vrf1 — a
#   live leafref into VRF_LIST — so sonic_yang rejected leaf01 /VRF removal
#   ("points to a non-existing leaf"), stage 1 exited 1, and stage 3 (re-add of
#   the seed rows) never ran. The chain's WARN-continue then re-recorded the
#   four spike-baseline-* proofs against that half-removed lab, and A-dry's
#   "no difference" was meaningless (fresh captures vs captures recorded 30s
#   earlier on the same broken state). Chain4 was killed; the baselines it
#   recorded at 14:08 are garbage and get overwritten by this chain's phase A.
# Fix applied to scripts/spike/seed-restore.sh (this session):
#   stage-1 removal order is now dependents-of-/VRF first:
#   SRV6_MY_SIDS -> SRV6_MY_LOCATORS -> INTERFACE -> VRF -> BGP_NEIGHBOR ->
#   LOOPBACK_INTERFACE. Validated live 14:14: full run exit 0, seed BGP
#   converged (v4 leaf01=2 leaf02=1 spine01=1 spine02=2; v6 leaf01=1 leaf02=1
#   spine01=0 spine02=2), locator rows none on all four nodes.
# Chain5 hardening vs chain4: an A-seed failure now ABORTS the chain
# (lab_sick) instead of continuing — baselines recorded on a non-seeded lab
# are exactly the integrity failure chain4 produced.
# Otherwise identical to chain4: health gate (no re-provision), then PHASE
# A..G (canonical re-record orders, receipt/fallback/containment design).
set -u
cd /root/agentic-netops || exit 9
P=.wiggum/features/004-srv6-service-requests/gates/proofs
BK=/tmp/g3/backup
mkdir -p "$BK"
# shellcheck disable=SC1091
. scripts/spike/spike-env.sh
# shellcheck disable=SC1091
. scripts/spike/ensure-fabric.sh
log() { echo "##### $(date +%H:%M:%S) $*"; }

step() { # step <name> <argv...>
  local n=$1; shift
  log "START $n: $*"
  "$@" > "/tmp/g3/$n.log" 2>&1
  echo $? > "/tmp/g3/$n.rc"
  log "RC $n=$(cat "/tmp/g3/$n.rc")"
}

converge() { # ensure the spike fabric state (fast path when already converged),
             # then require all four nodes H-OK=1
  ensure_fabric
  local n r rc=0
  for n in leaf01 leaf02 spine01 spine02; do
    r=$(_ensure_fabric_probe "$n" | tail -1)
    echo "$n: $r"
    [ "$r" = "H-OK=1" ] || rc=1
  done
  return $rc
}

canary() { # 0 = lab can program + forward. All device reads go through the
           # node read path (node_run), never docker exec into the launcher.
  local r out
  bash scripts/spike/vrf-apply.sh leaf01 >/tmp/g3/canary-l1.log 2>&1 \
    || { echo "CANARY-FAIL vrf-apply leaf01: $(tail -1 /tmp/g3/canary-l1.log)"; return 1; }
  r=$(node_run "$(container_of leaf01)" "ip link show Vrf1" 2>&1) \
    || { echo "CANARY-FAIL leaf01 kernel Vrf1 missing (node path): $(tail -1 <<<"$r")"; return 1; }
  bash scripts/spike/vrf-apply.sh leaf02 >/tmp/g3/canary-l2.log 2>&1 \
    || { echo "CANARY-FAIL vrf-apply leaf02: $(tail -1 /tmp/g3/canary-l2.log)"; return 1; }
  r=$(node_run "$(container_of leaf02)" "ip link show Vrf1" 2>&1) \
    || { echo "CANARY-FAIL leaf02 kernel Vrf1 missing (node path): $(tail -1 <<<"$r")"; return 1; }
  bash scripts/spike/vpn-setup.sh >/tmp/g3/canary-vpnsetup.log 2>&1 \
    || { echo "CANARY-FAIL vpn-setup: $(tail -1 /tmp/g3/canary-vpnsetup.log)"; return 1; }
  out=$(client_run "$C_srv6_client01" "ping -c3 -W2 192.168.2.2 2>&1 | tail -2" 2>&1)
  echo "$out" | grep -qE ', [1-9][0-9]* received' \
    || { echo "CANARY-FAIL dataplane: $out"; return 1; }
  echo CANARY-OK
}

recover() { # one provision + settle + converge + canary; 0 = healthy again
  step "PROV" ./scripts/provision.sh --profile sonic-vm
  local up
  up=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^clab-agentic-netops-fabric-')
  [ "${up:-0}" -ge 8 ] || { echo "lab down after provision (up=$up, rc=$(cat /tmp/g3/PROV.rc))"; return 1; }
  sleep 90
  step R-conv converge
  [ "$(cat /tmp/g3/R-conv.rc)" = 0 ] || { echo "recovery converge incomplete"; return 1; }
  step R-canary canary
  [ "$(cat /tmp/g3/R-canary.rc)" = 0 ]
}

lab_sick() { # LAB-SICK containment: finish immediately, record nothing further
  log "LAB-SICK: $1"
  summary "LAB-SICK: $1"
  echo "CHAIN4-DONE(lab-sick) $(date +%H:%M:%S)" > /tmp/g3/chain5.done
  exit 1
}

backup_group() { # cp stored outs/cmds of a group aside before a risky re-record
  local f
  for f in "$P"/"$1"*; do
    [ -f "$f" ] && cp "$f" "$BK/$(basename "$f")"
  done
}

restore_group() { # undo a poisoned re-record attempt
  local f b
  for f in "$BK"/"$1"*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    cp "$f" "$P/$b"
  done
}

receipt() { # receipt <name> <group-prefix> — record the replay receipt + verdict
  local n=$1 g=$2
  step "$n" scripts/proof.sh "$n" -- scripts/proof.sh replay "$g"
  if grep -q '^differ:' "$P/$n.out" 2>/dev/null; then
    echo differ > "/tmp/g3/$n.verdict"
  else
    echo clean > "/tmp/g3/$n.verdict"
  fi
  log "RECEIPT $n verdict=$(cat "/tmp/g3/$n.verdict")"
}

rerecord_vpn() {
  # prep (unrecorded): return the lab to the group's canonical torn-down
  # starting point — spike-vpn-state-leaf01 (vrf-apply) is the first capture.
  bash scripts/spike/vpn-rollback.sh >/tmp/g3/RV-prep.log 2>&1 || true
  rm -f /tmp/g3/RV*.rc
  step RV1 scripts/proof.sh spike-vpn-state-leaf01    -- scripts/spike/vrf-apply.sh leaf01
  step RV2 scripts/proof.sh spike-vpn-state-leaf02    -- scripts/spike/vrf-apply.sh leaf02
  step RV3 scripts/proof.sh spike-vpn-ping            -- scripts/spike/vpn-ping.sh
  step RV4 scripts/proof.sh spike-vpn-capture         -- scripts/spike/vpn-capture.sh
  step RV5 scripts/proof.sh spike-vpn-readback-leaf01 -- bash scripts/spike/vpn-readback.sh leaf01
  step RV6 scripts/proof.sh spike-vpn-readback-leaf02 -- bash scripts/spike/vpn-readback.sh leaf02
  step RV7 scripts/proof.sh spike-vpn-clients         -- bash scripts/spike/vpn-clients.sh
  step RV8 scripts/proof.sh spike-vpn-rollback        -- bash scripts/spike/vpn-rollback.sh
  local bad=0 f
  for f in /tmp/g3/RV*.rc; do [ "$(cat "$f")" = 0 ] || bad=1; done
  return $bad
}

rerecord_evpn3() {
  rm -f /tmp/g3/R3-*.rc
  step R3-1 scripts/proof.sh spike-evpn3-ping          -- bash scripts/spike/evpn3-ping.sh
  step R3-2 scripts/proof.sh spike-evpn3-capture       -- bash scripts/spike/evpn3-capture.sh
  step R3-3 scripts/proof.sh spike-evpn3-kl006         -- bash scripts/spike/evpn3-kl006.sh
  step R3-4 scripts/proof.sh spike-evpn3-rollback      -- bash scripts/spike/evpn3-rollback.sh
  step R3-5 scripts/proof.sh spike-evpn3-state-leaf01  -- bash scripts/spike/evpn3-state.sh leaf01
  step R3-6 scripts/proof.sh spike-evpn3-state-leaf02  -- bash scripts/spike/evpn3-state.sh leaf02
  local bad=0 f
  for f in /tmp/g3/R3-*.rc; do [ "$(cat "$f")" = 0 ] || bad=1; done
  return $bad
}

rerecord_evpn2() {
  rm -f /tmp/g3/R2-*.rc
  step R2-1 scripts/proof.sh spike-evpn2-state-leaf01  -- bash scripts/spike/evpn2-state.sh leaf01
  step R2-2 scripts/proof.sh spike-evpn2-state-leaf02  -- bash scripts/spike/evpn2-state.sh leaf02
  step R2-3 scripts/proof.sh spike-evpn2-ping          -- bash scripts/spike/evpn2-ping.sh
  step R2-4 scripts/proof.sh spike-evpn2-capture       -- bash scripts/spike/evpn2-capture.sh
  step R2-5 scripts/proof.sh spike-evpn2-rollback      -- bash scripts/spike/evpn2-rollback.sh
  local bad=0 f
  for f in /tmp/g3/R2-*.rc; do [ "$(cat "$f")" = 0 ] || bad=1; done
  return $bad
}

fallback() { # fallback <receipt-name> <group-prefix> <rerecord-fn>
  local rn=$1 g=$2 fn=$3
  step "FG-$g-canary" canary
  if ! [ "$(cat /tmp/g3/FG-$g-canary.rc)" = 0 ]; then
    log "fallback $g: canary failed — one provision-recovery"
    step "FG-$g-recover" recover
    [ "$(cat /tmp/g3/FG-$g-recover.rc)" = 0 ] || lab_sick "fallback $g: provision+canary failed ($(tail -1 /tmp/g3/FG-$g-recover.log))"
  fi
  backup_group "$g-"
  if ! "$fn"; then
    log "FALLBACK $g: re-record had failing steps — converge+one bounded retry"
    step "FG-$g-conv" converge
    if ! "$fn"; then
      log "FALLBACK $g: re-record failed twice — restoring previous stored records"
      restore_group "$g-"
      return 1
    fi
  fi
  receipt "$rn" "$g"
}

summary() {
  {
    echo "H-conv=$(cat /tmp/g3/H-conv.rc 2>/dev/null)"
    echo "H-canary=$(cat /tmp/g3/H-canary.rc 2>/dev/null)"
    echo "A-seed=$(cat /tmp/g3/A-seed.rc 2>/dev/null)"
    echo "A-dry=$(cat /tmp/g3/A-dry.rc 2>/dev/null)"
    echo "B-conv=$(cat /tmp/g3/B-conv.rc 2>/dev/null)"
    for r in spike-rerun-vpn spike-rerun-steering spike-rerun-evpn3 spike-rerun-evpn2 spike-rerun-baseline; do
      echo "$r=$(cat "/tmp/g3/$r.verdict" 2>/dev/null || echo missing)"
    done
    for r in spike-rerun-vpn spike-rerun-steering spike-rerun-evpn3 spike-rerun-evpn2 spike-rerun-baseline; do
      [ -f "/tmp/g3/$r.verdict" ] && [ "$(cat "/tmp/g3/$r.verdict")" = differ ] \
        && echo "  NOTE $r: $(grep '^differ:' "$P/$r.out" 2>/dev/null | tr '\n' ' ')"
    done
    [ -n "${1:-}" ] && echo "FINAL: $1"
  } > /tmp/g3/chain5.summary 2>&1
}

# ---- PHASE H: health gate on the already-fresh lab (no re-provision) ----------
rm -f /tmp/g3/chain5.done /tmp/g3/chain5.summary /tmp/g3/spike-rerun-*.verdict
up=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^clab-agentic-netops-fabric-')
[ "${up:-0}" -ge 8 ] || lab_sick "lab down at start (up=$up) — needs scripts/provision.sh first"
step H-conv converge
if ! [ "$(cat /tmp/g3/H-conv.rc)" = 0 ]; then
  log "converge incomplete; settling 120s and re-probing"
  sleep 120
  step H-conv2 converge
  [ "$(cat /tmp/g3/H-conv2.rc)" = 0 ] || lab_sick "converge incomplete: $(grep 'H-OK=0' /tmp/g3/H-conv2.log | head -2 | tr '\n' ' ')"
fi
step H-canary canary
[ "$(cat /tmp/g3/H-canary.rc)" = 0 ] || lab_sick "canary failed ($(cat /tmp/g3/H-canary.log))"
log "PHASE H done: lab healthy (converge + fixed canary; no re-provision)"

# ---- PHASE A: seed state + baseline re-record x4 + dry replay -----------------
step A-seed bash scripts/spike/seed-restore.sh
[ "$(cat /tmp/g3/A-seed.rc)" = 0 ] || lab_sick "A-seed failed rc=$(cat /tmp/g3/A-seed.rc) ($(tail -2 /tmp/g3/A-seed.log | tr '\n' ' ')) — baselines NOT re-recorded (would capture a non-seeded lab)"
for n in spine01 spine02 leaf01 leaf02; do
  step "A-b-$n" scripts/proof.sh "spike-baseline-$n" -- scripts/spike/baseline-capture.sh "$n"
done
step A-dry scripts/proof.sh replay spike-baseline
if ! [ "$(cat /tmp/g3/A-dry.rc)" = 0 ]; then
  log "A-dry differs — one bounded baseline re-record"
  for n in spine01 spine02 leaf01 leaf02; do
    step "A-b2-$n" scripts/proof.sh "spike-baseline-$n" -- scripts/spike/baseline-capture.sh "$n"
  done
  step A-dry scripts/proof.sh replay spike-baseline
fi
log "PHASE A done (seed=$(cat /tmp/g3/A-seed.rc) dry=$(cat /tmp/g3/A-dry.rc))"

# ---- PHASE B: converge the bootstrap for the service groups -------------------
step B-conv converge
if ! [ "$(cat /tmp/g3/B-conv.rc)" = 0 ]; then
  log "B-conv incomplete; settling 120s and re-probing"
  sleep 120
  step B-conv2 converge
  [ "$(cat /tmp/g3/B-conv2.rc)" = 0 ] || lab_sick "service-group converge incomplete: $(grep 'H-OK=0' /tmp/g3/B-conv2.log | head -2 | tr '\n' ' ')"
fi
log "PHASE B done"

# ---- PHASE C: T106 vpn receipt (fallback: recover + re-record + receipt) ------
receipt spike-rerun-vpn spike-vpn
if [ "$(cat /tmp/g3/spike-rerun-vpn.verdict)" = differ ]; then
  log "vpn receipt differs — fallback path"
  fallback spike-rerun-vpn spike-vpn rerecord_vpn || log "vpn fallback exhausted; verdict stands"
fi
log "PHASE C done"

# ---- PHASE D: T109 steering re-record x5 + receipt ----------------------------
steer_step() { # steer_step <name> <argv...> — one bounded converge+retry on rc!=0
  local n=$1; shift
  step "$n" "$@"
  if ! [ "$(cat /tmp/g3/$n.rc)" = 0 ]; then
    log "$n rc!=0 — converge + one bounded retry"
    step "$n-conv" converge
    step "$n-r2" "$@"
  fi
}
steer_step D-1 scripts/proof.sh spike-steering-path              -- bash scripts/spike/steering-path.sh
steer_step D-2 scripts/proof.sh spike-steering-failover-launcher -- bash scripts/spike/steering-failover.sh launcher
steer_step D-3 scripts/proof.sh spike-steering-failover-guest-if -- bash scripts/spike/steering-failover.sh guest
steer_step D-4 scripts/proof.sh spike-steering-failover-bgp      -- bash scripts/spike/steering-failover.sh bgp
steer_step D-5 scripts/proof.sh spike-steering-return            -- bash scripts/spike/steering-failover.sh return
receipt spike-rerun-steering spike-steering
log "PHASE D done"

# ---- PHASE E/F: T108 evpn receipts with fallbacks -----------------------------
receipt spike-rerun-evpn3 spike-evpn3
[ "$(cat /tmp/g3/spike-rerun-evpn3.verdict)" = differ ] && { fallback spike-rerun-evpn3 spike-evpn3 rerecord_evpn3 || log "evpn3 fallback exhausted"; }
receipt spike-rerun-evpn2 spike-evpn2
[ "$(cat /tmp/g3/spike-rerun-evpn2.verdict)" = differ ] && { fallback spike-rerun-evpn2 spike-evpn2 rerecord_evpn2 || log "evpn2 fallback exhausted"; }
log "PHASE E/F done"

# ---- PHASE G: T105 seed restore + baseline receipt ----------------------------
step G-seed bash scripts/spike/seed-restore.sh
if ! [ "$(cat /tmp/g3/G-seed.rc)" = 0 ]; then
  log "G-seed rc!=0 — one bounded retry after settle"
  sleep 60
  step G-seed2 bash scripts/spike/seed-restore.sh
fi
receipt spike-rerun-baseline spike-baseline
log "PHASE G done"

summary ""
echo "CHAIN4-DONE $(date +%H:%M:%S)" > /tmp/g3/chain5.done
log "CHAIN4 DONE — summary in /tmp/g3/chain5.summary"
