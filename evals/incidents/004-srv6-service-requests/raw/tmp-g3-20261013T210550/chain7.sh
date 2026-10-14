#!/usr/bin/env bash
# chain7.sh — chain6 minus its completed phases, resumed after the keeper abort.
# chain6 (14:42-19:17, /tmp/g3/chain6.log, keeper-killed): phases H/A/B done green;
# the T106 vpn group was RE-RECORDED green on this deploy (RV1..RV8, 16:57-17:06,
# all rc=0, right after the 16:42 provision-recovery) but its receipt differ'd
# (17:06-17:59: 7/8 APPLY-STUCK at replay — the 5th orchagent wedge); phase D
# (steering) recorded four PREFLIGHT-FAILED outs before the keeper killed D-5
# mid-run; E/F/G never ran.
# Since abort (19:15-19:22): lab healed in-guest on both leaves (reset-failed+
# start swss/syncd/bgp — NOT docker restart, which trips start-limit; APPL_DB
# VRF_TABLE repopulated, kernel Vrf1 back), and scripts/spike/vrf-apply.sh gained
# the silent vrf_wedge_cure (probe-fail + CONFIG_DB-present/APPL_DB-empty
# signature -> same cure, byte-identical outputs on success). Inline pre-check on
# resume (19:5x): vrf-apply leaf01/leaf02 rc=0, vpn-setup rc=0, client01->client02
# ping 0% loss — service applied, the exact pre-state the stored RV records have.
# chain7 therefore:
#   H2  steering-leftover cleanup (D-phase scripts self-restore via steer_off,
#       but the keeper killed D-5 before its restore could run: assert links up,
#       the bgp-mode neighbour unshut, steer_off) + the chain6 health gate
#       (converge + canary, provision-recovery ladder unchanged);
#   C   T106 vpn receipt; differ -> the chain6 fallback (canary/recover +
#       rerecord_vpn + receipt);
#   D   steering x5 re-record (the stored steering outs are recorded failures —
#       overwritten by canonical re-record, never hand-edited) + T109 receipt;
#   E/F T107/T108 evpn receipts with the chain6 fallbacks;
#   G   T105 seed-restore + baseline receipt + ONE bounded canonical re-record
#       after a fresh seed if the cross-deploy replay differs (chain6 phase A
#       recorded the baselines green on the pre-16:42 deploy; this receipt is
#       what decides, and the retry re-records — never edits bytes).
set -u
cd /root/agentic-netops || exit 9
P=.wiggum/features/004-srv6-service-requests/gates/proofs
BK=/tmp/g3/backup
mkdir -p "$BK"
# shellcheck disable=SC1091
. scripts/spike/spike-env.sh
# shellcheck disable=SC1091
. scripts/spike/ensure-fabric.sh
# shellcheck disable=SC1091
. scripts/spike/steering-lib.sh
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
  echo "CHAIN7-DONE(lab-sick) $(date +%H:%M:%S)" > /tmp/g3/chain7.done
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

clean_steering() { # undo any steering-run leftover (the chain6 D scripts are
                   # self-restoring, but the keeper killed D-5 before its
                   # restore ran): pins off, links up, neighbour unshut.
  local c1
  steer_off || true
  c1=$(container_of leaf01)
  node_run "$c1" "sudo ip link set Ethernet0 up" >/dev/null 2>&1 || true
  docker exec "$c1" ip link set eth1 up >/dev/null 2>&1 || true
  node_run "$c1" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'no neighbor 10.1.0.0 shutdown' -c 'end'" >/dev/null 2>&1 || true
  echo STEER-CLEAN-OK
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
    echo "chain7 = chain6 minus its completed phases (H/A/B), after the keeper abort"
    echo "19:17 and the in-guest heal 19:15-19:22 (reset-failed+start swss/syncd/bgp;"
    echo "vrf_wedge_cure added to scripts/spike/vrf-apply.sh, silent on success)."
    echo "chain6 pre-abort facts: A-seed=0 A-dry=0 B-conv=0; vpn group re-recorded"
    echo "green (RV1..RV8 rc=0, 16:57-17:06, this deploy); its receipt differ'd on the"
    echo "wedged lab and is re-run below; steering outs are recorded failures and are"
    echo "re-recorded below (canonical order, never hand-edited)."
    echo "H2-clean=$(cat /tmp/g3/H2-clean.rc 2>/dev/null)"
    echo "H2-conv=$(cat /tmp/g3/H2-conv.rc 2>/dev/null)"
    echo "H2-canary=$(cat /tmp/g3/H2-canary.rc 2>/dev/null)"
    echo "H2-recover1=$(cat /tmp/g3/H2-recover1.rc 2>/dev/null)"
    echo "H2-recover2=$(cat /tmp/g3/H2-recover2.rc 2>/dev/null)"
    for r in spike-rerun-vpn spike-rerun-steering spike-rerun-evpn3 spike-rerun-evpn2 spike-rerun-baseline; do
      echo "$r=$(cat "/tmp/g3/$r.verdict" 2>/dev/null || echo missing)"
    done
    for r in spike-rerun-vpn spike-rerun-steering spike-rerun-evpn3 spike-rerun-evpn2 spike-rerun-baseline; do
      [ -f "/tmp/g3/$r.verdict" ] && [ "$(cat "/tmp/g3/$r.verdict")" = differ ] \
        && echo "  NOTE $r: $(grep '^differ:' "$P/$r.out" 2>/dev/null | tr '\n' ' ')"
    done
    [ -n "${1:-}" ] && echo "FINAL: $1"
  } > /tmp/g3/chain7.summary 2>&1
}

# ---- PHASE H2: steering-leftover cleanup + health gate (no re-provision) ------
rm -f /tmp/g3/chain7.done /tmp/g3/chain7.summary /tmp/g3/spike-rerun-*.verdict
up=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^clab-agentic-netops-fabric-')
[ "${up:-0}" -ge 8 ] || lab_sick "lab down at start (up=$up) — needs scripts/provision.sh first"
step H2-clean clean_steering
step H2-conv converge
if ! [ "$(cat /tmp/g3/H2-conv.rc)" = 0 ]; then
  log "converge incomplete; settling 120s and re-probing"
  sleep 120
  step H2-conv2 converge
  [ "$(cat /tmp/g3/H2-conv2.rc)" = 0 ] || lab_sick "converge incomplete: $(grep 'H-OK=0' /tmp/g3/H2-conv2.log | head -2 | tr '\n' ' ')"
fi
step H2-canary canary
if ! [ "$(cat /tmp/g3/H2-canary.rc)" = 0 ]; then
  log "canary failed ($(tail -1 /tmp/g3/H2-canary.log)) — known orchagent wedge; provision-recovery attempt 1"
  step H2-recover1 recover
  if ! [ "$(cat /tmp/g3/H2-recover1.rc)" = 0 ]; then
    log "recovery attempt 1 failed ($(tail -1 /tmp/g3/R-canary.log 2>/dev/null)) — provision-recovery attempt 2"
    step H2-recover2 recover
    [ "$(cat /tmp/g3/H2-recover2.rc)" = 0 ] || lab_sick "canary failed and two provision-recoveries failed (last R-canary: $(tail -1 /tmp/g3/R-canary.log 2>/dev/null))"
  fi
fi
log "PHASE H2 done: lab healthy (clean + converge + canary; recovery used if canary failed once)"

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

# ---- PHASE E/F: T107/T108 evpn receipts with fallbacks ------------------------
receipt spike-rerun-evpn3 spike-evpn3
[ "$(cat /tmp/g3/spike-rerun-evpn3.verdict)" = differ ] && { fallback spike-rerun-evpn3 spike-evpn3 rerecord_evpn3 || log "evpn3 fallback exhausted"; }
receipt spike-rerun-evpn2 spike-evpn2
[ "$(cat /tmp/g3/spike-rerun-evpn2.verdict)" = differ ] && { fallback spike-rerun-evpn2 spike-evpn2 rerecord_evpn2 || log "evpn2 fallback exhausted"; }
log "PHASE E/F done"

# ---- PHASE G: T105 seed restore + baseline receipt (+ one bounded re-record) ---
step G-seed bash scripts/spike/seed-restore.sh
if ! [ "$(cat /tmp/g3/G-seed.rc)" = 0 ]; then
  log "G-seed rc!=0 — one bounded retry after settle"
  sleep 60
  step G-seed2 bash scripts/spike/seed-restore.sh
fi
receipt spike-rerun-baseline spike-baseline
if [ "$(cat /tmp/g3/spike-rerun-baseline.verdict)" = differ ]; then
  log "baseline receipt differs — one bounded canonical re-record after a fresh seed"
  step G-seed3 bash scripts/spike/seed-restore.sh
  for n in spine01 spine02 leaf01 leaf02; do
    step "G-b-$n" scripts/proof.sh "spike-baseline-$n" -- scripts/spike/baseline-capture.sh "$n"
  done
  receipt spike-rerun-baseline spike-baseline
fi
log "PHASE G done"

summary ""
echo "CHAIN7-DONE $(date +%H:%M:%S)" > /tmp/g3/chain7.done
log "CHAIN7 DONE — summary in /tmp/g3/chain7.summary"
