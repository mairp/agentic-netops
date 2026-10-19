#!/usr/bin/env bash
# seed-restore.sh — bring the four sonic-vm guests back to the EXACT seed
# fabric state the phase-3 baseline proofs captured (spike-baseline-*.out,
# recorded on the freshly provisioned lab before any spike change, T105).
#
# The seed is the partial underlay the provision-time qualification bring-up
# leaves behind: DEVICE_METADATA already §7-identical (hostname, ASN, router
# id, bgp_adv_lo_prefix_as_128), LOOPBACK_INTERFACE identical to §7, but the
# BGP_NEIGHBOR table is PARTIAL and ASYMMETRIC:
#   spine01: only leaf01 v4 (10.1.0.1)          — no v6, no leaf02, no iBGP
#   spine02: leaf01+leaf02 v4+v6 + iBGP to spine01 via loopbacks (10.0.0.11)
#   leaf01/02: all 4 §7 neighbors (2 spines, v4+v6)
# so the seeded BGP topology converges to: leaf01 v4 est=2, leaf02 v4 est=1,
# spine01 est=1, spine02 v4 est=2 + v6 est=2; every v6 session on spine01
# stays Active (the spine has no v6 rows) — deterministic.
#
# What this script undoes (all spike additions on top of the seed):
#   - SRV6_MY_LOCATORS rows (FRR locators die with the bgp restart)
#   - /VRF + the service /INTERFACE rows (via scripts/spike/vpn-rollback.sh)
#   - the lingering kernel Vrf1 device (the image keeps the device after the
#     config rows are gone; the factory seed has none)
#   - metric-5 /48 pin routes + proto-196 zebra statics + seg6local routes
#   - vtysh-only state (allowas-in, update-source, EVPN config) — the restart
#     re-renders from CONFIG_DB, which drops all of it
# then wipes and re-adds BGP_NEIGHBOR / INTERFACE / LOOPBACK_INTERFACE from the
# embedded seed rows and restarts bgp so bgpcfgd re-renders the seed config.
#
# HOW patches reach the guest: push_file (base64 over the node_exec channel)
# + `sudo config apply-patch` INSIDE the guest. Two earlier traps are recorded
# here so they never come back: (1) this image has NO `config gcu`
# subcommand — the GCU entrypoint is the top-level `config apply-patch`;
# (2) `docker cp <container>` lands in the launcher container's filesystem,
# which the guest VM never sees. Both were silent no-ops (stderr discarded,
# `|| true`), so the 03:52 run half-restored the seed: spine01 kept its
# converged BGP_NEIGHBOR rows → the iBGP session flapped between captures →
# the baseline dry replay differed. Every stage now VERIFIES its effect in
# CONFIG_DB and hard-fails instead of pretending.
#
# NOT recorded as a proof: this is prep tooling for T105; the proof is
#   scripts/proof.sh replay spike-baseline  (byte-compare against the stored
#   pre-change captures).

set -u
SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SPIKE_DIR/spike-env.sh"

# Per-node seed rows extracted verbatim from the stored pre-change captures
# (gates/proofs/spike-baseline-<node>.out, "show runningconfig all" JSON).
SEED_ROWS='
{
 "leaf01": {
  "BGP_NEIGHBOR": {
   "10.1.0.0": {
    "asn": "65000",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "10.1.0.1",
    "nhopself": "0",
    "rrclient": "0"
   },
   "10.1.0.4": {
    "asn": "65000",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "10.1.0.5",
    "nhopself": "0",
    "rrclient": "0"
   },
   "2001:db8:1::3": {
    "asn": "65000",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "2001:db8:1::2",
    "nhopself": "0",
    "rrclient": "0"
   },
   "2001:db8:2::3": {
    "asn": "65000",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "2001:db8:2::2",
    "nhopself": "0",
    "rrclient": "0"
   }
  },
  "INTERFACE": {
   "Ethernet0": {},
   "Ethernet0|10.1.0.1/31": {},
   "Ethernet0|2001:db8:1::2/127": {},
   "Ethernet4": {},
   "Ethernet4|10.1.0.5/31": {},
   "Ethernet4|2001:db8:2::2/127": {}
  },
  "LOOPBACK_INTERFACE": {
   "Loopback0": {},
   "Loopback0|10.0.0.21/32": {},
   "Loopback0|2001:db8:ff::21/128": {}
  }
 },
 "leaf02": {
  "BGP_NEIGHBOR": {
   "10.1.0.2": {
    "asn": "65000",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "10.1.0.3",
    "nhopself": "0",
    "rrclient": "0"
   },
   "10.1.0.6": {
    "asn": "65000",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "10.1.0.7",
    "nhopself": "0",
    "rrclient": "0"
   },
   "2001:db8:1::5": {
    "asn": "65000",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "2001:db8:1::4",
    "nhopself": "0",
    "rrclient": "0"
   },
   "2001:db8:2::5": {
    "asn": "65000",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "2001:db8:2::4",
    "nhopself": "0",
    "rrclient": "0"
   }
  },
  "INTERFACE": {
   "Ethernet0": {},
   "Ethernet0|10.1.0.3/31": {},
   "Ethernet0|2001:db8:1::4/127": {},
   "Ethernet4": {},
   "Ethernet4|10.1.0.7/31": {},
   "Ethernet4|2001:db8:2::4/127": {}
  },
  "LOOPBACK_INTERFACE": {
   "Loopback0": {},
   "Loopback0|10.0.0.22/32": {},
   "Loopback0|2001:db8:ff::22/128": {}
  }
 },
 "spine01": {
  "BGP_NEIGHBOR": {
   "10.1.0.1": {
    "asn": "65101",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "10.1.0.0",
    "nhopself": "0",
    "rrclient": "0"
   }
  },
  "INTERFACE": {
   "Ethernet0": {},
   "Ethernet0|10.1.0.0/31": {},
   "Ethernet0|2001:db8:1::3/127": {},
   "Ethernet4": {},
   "Ethernet4|10.1.0.2/31": {},
   "Ethernet4|2001:db8:1::5/127": {}
  },
  "LOOPBACK_INTERFACE": {
   "Loopback0": {},
   "Loopback0|10.0.0.11/32": {},
   "Loopback0|2001:db8:ff::11/128": {}
  }
 },
 "spine02": {
  "BGP_NEIGHBOR": {
   "10.0.0.11": {
    "asn": "65000",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "10.0.0.12",
    "nhopself": "0",
    "rrclient": "0"
   },
   "10.1.0.5": {
    "asn": "65101",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "10.1.0.4",
    "nhopself": "0",
    "rrclient": "0"
   },
   "10.1.0.7": {
    "asn": "65102",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "10.1.0.6",
    "nhopself": "0",
    "rrclient": "0"
   },
   "2001:db8:2::2": {
    "asn": "65101",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "2001:db8:2::3",
    "nhopself": "0",
    "rrclient": "0"
   },
   "2001:db8:2::4": {
    "asn": "65102",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "2001:db8:2::5",
    "nhopself": "0",
    "rrclient": "0"
   },
   "2001:db8:ff::11": {
    "asn": "65000",
    "holdtime": "180",
    "keepalive": "60",
    "local_addr": "2001:db8:ff::12",
    "nhopself": "0",
    "rrclient": "0"
   }
  },
  "INTERFACE": {
   "Ethernet0": {},
   "Ethernet0|10.1.0.4/31": {},
   "Ethernet0|2001:db8:2::3/127": {},
   "Ethernet4": {},
   "Ethernet4|10.1.0.6/31": {},
   "Ethernet4|2001:db8:2::5/127": {}
  },
  "LOOPBACK_INTERFACE": {
   "Loopback0": {},
   "Loopback0|10.0.0.12/32": {},
   "Loopback0|2001:db8:ff::12/128": {}
  }
 }
}
'

# table_keys <node> <table> — number of live CONFIG_DB rows under the table
table_keys() {
    local c
    c=$(container_of "$1")
    node_run "$c" "sudo redis-cli -n 4 --raw KEYS '$2|*'" 2>/dev/null | grep -c . || true
}

# cfg_apply <node> <json-file> — push the patch into the GUEST VM (push_file;
# docker cp would land in the launcher container, invisible to the guest) and
# apply it with `config apply-patch`. stderr is surfaced and the rc reflects
# the apply, so a failed patch can never masquerade as success again.
cfg_apply() { # cfg_apply <node> <json-file>
    local c out
    c=$(container_of "$1") || return 1
    push_file "$c" "$2" /tmp/patch.json || { echo "FAIL: push_file $2 -> $1"; return 1; }
    out=$(node_run "$c" "sudo config apply-patch /tmp/patch.json" 2>&1) || {
        printf '%s\n' "$out" | tail -3
        return 1
    }
    return 0
}

kernel_cleanup() { # kernel_cleanup <node>
    local c
    c=$(container_of "$1")
    node_run "$c" bash -s >/dev/null 2>&1 <<'K' || true
# pin routes (/48 via) + proto 196 zebra statics
ip -6 route show scope global | while read -r line; do
    case "$line" in
        *via*fcbb*|*proto\ 196*) set -- $line; ip -6 route del "$1" 2>/dev/null || true ;;
    esac
done
# any leftover seg6local (End.DT46) routes
ip -6 route show | grep -q seg6local && ip -6 route flush scope global type local 2>/dev/null || true
K
}

echo "===== stage 1: kernel cleanup + verified table removals (all nodes) ====="
rc=0
for n in spine01 spine02 leaf01 leaf02; do
    echo "--- $n"
    kernel_cleanup "$n"
    # SRV6_MY_SIDS first: its decap_vrf is a live leafref into VRF_LIST, so
    # removing /VRF while the row exists is rejected by sonic_yang (measured:
    # 2026-10-13 chain2 stage 1 "points to a non-existing leaf"). Same ordering
    # vpn-rollback.sh already applies. INTERFACE second: the SERVICE attachment
    # row (INTERFACE|Ethernet12|... with vrf_name=Vrf1) is the same leafref in
    # the other direction, so /VRF removal is rejected while it exists either
    # way (measured: 2026-10-13 chain4 stage 1 rejected leaf01 /VRF with the
    # seed INTERFACE rows already gone but Ethernet12's vrf_name still pointing
    # into VRF_LIST). Removal order: dependents of /VRF before /VRF itself.
    for t in SRV6_MY_SIDS SRV6_MY_LOCATORS INTERFACE VRF BGP_NEIGHBOR LOOPBACK_INTERFACE; do
        [ "$(table_keys "$n" "$t")" = "0" ] && continue
        tmp=$(mktemp)
        printf '[{"op":"remove","path":"/%s"}]' "$t" > "$tmp"
        # one table per patch: GCU rejects the WHOLE patch if any single op
        # targets a non-existent object (measured: "can't remove a
        # non-existent object 'VRF'" killed the earlier 5-op patch).
        if ! cfg_apply "$n" "$tmp" || [ "$(table_keys "$n" "$t")" != "0" ]; then
            echo "FAIL: $n /$t removal did not take (keys now: $(table_keys "$n" "$t"))"
            rc=1
        fi
        rm -f "$tmp"
    done
done
[ "$rc" = 0 ] || { echo "stage 1 FAILED — CONFIG_DB not clean; refusing to fake a seed"; exit 1; }

echo "===== stage 2: service rollback (Vrf1, client attach) ====="
rb_rc=0
"$SPIKE_DIR/vpn-rollback.sh" >/dev/null 2>&1 || rb_rc=$?
# the image keeps the kernel Vrf1 device after the config rows are gone
# (recorded honestly by spike-vpn-rollback); the factory seed has none, and
# baseline-capture would print it — delete it so the restored seed matches.
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    node_run "$c" "ip link show Vrf1 >/dev/null 2>&1 && sudo ip link del Vrf1" >/dev/null 2>&1 || true
done
[ "$rb_rc" = 0 ] || echo "WARN: vpn-rollback rc=$rb_rc (its own markers judge it)"
echo "===== stage 3: re-add seed rows (per node, verified) ====="
export SEED_ROWS
python3 - <<'PY' || { echo "FAIL: cannot render seed patches"; exit 1; }
import json, os
seed = json.loads(os.environ["SEED_ROWS"])
for n, tables in seed.items():
    for t, rows in tables.items():
        patch = json.dumps([{"op": "add", "path": f"/{t}", "value": rows}])
        open(f"/tmp/seed-{n}-{t}.json", "w").write(patch)
PY
rc=0
for n in spine01 spine02 leaf01 leaf02; do
    echo "--- $n"
    for t in LOOPBACK_INTERFACE INTERFACE BGP_NEIGHBOR; do
        f="/tmp/seed-$n-$t.json"
        [[ -f "$f" ]] || continue
        want=$(python3 -c "import json;print(len(json.load(open('$f'))[0]['value']))")
        if ! cfg_apply "$n" "$f" || [ "$(table_keys "$n" "$t")" != "$want" ]; then
            echo "FAIL: $n /$t re-add (keys now: $(table_keys "$n" "$t"), want: $want)"
            rc=1
        fi
        rm -f "$f"
    done
done
[ "$rc" = 0 ] || { echo "stage 3 FAILED — seed rows incomplete"; exit 1; }

echo "===== stage 4: bgp restart (re-render from restored CONFIG_DB) ====="
for n in spine01 spine02 leaf01 leaf02; do
    echo "--- $n"
    bgp_container_restart "$n" || echo "WARN: bgp not ready on $n"
done

echo "===== stage 5: seed convergence wait (v4 + v6 session counts) ====="
declare -A WANT_V4=( [leaf01]=2 [leaf02]=1 [spine01]=1 [spine02]=2 )
declare -A WANT_V6=( [leaf01]=1 [leaf02]=1 [spine01]=0 [spine02]=2 )
# leaf01/leaf02 keep v6 rows to both spines in the seed, but spine01 has no
# v6 BGP_NEIGHBOR rows — its v6 sessions stay Active, so each leaf holds
# exactly one established v6 session (to spine02). Deterministic (seed doc).
v6_est() { # v6_est <node> — established sessions in the v6 unicast summary
    node_run "$(container_of "$1")" "vtysh -c 'show bgp ipv6 unicast summary' | awk '/^[0-9a-fA-F:]*:/ && \$10 ~ /^[0-9]+\$/ {e++} END {print e+0}'" 2>/dev/null | tr -d '[:space:]'
}
for i in $(seq 1 30); do
    ok=1
    for n in leaf01 leaf02 spine01 spine02; do
        c=$(container_of "$n")
        got=$(node_run "$c" "vtysh -c 'show bgp ipv4 unicast summary' | awk '/^[0-9]+\./ && \$10 ~ /^[0-9]+\$/ {e++} END {print e+0}'" 2>/dev/null | tr -d '[:space:]')
        g6=$(v6_est "$n")
        [[ "$got" == "${WANT_V4[$n]}" ]] || ok=0
        [[ "$g6" == "${WANT_V6[$n]}" ]] || ok=0
    done
    [[ "$ok" == 1 ]] && { echo "seed BGP converged (v4: leaf01=2 leaf02=1 spine01=1 spine02=2; v6: leaf01=1 leaf02=1 spine01=0 spine02=2)"; break; }
    [[ "$i" == 30 ]] && echo "WARN: seed counts not reached in 90s; continuing (replay diff will judge)"
    sleep 3
done
# quiescence settle: the wait sees counts, not route-table stability; give
# the last renders a moment so two captures 2 minutes apart agree byte-wise.
sleep 15

echo "===== stage 6: read-back (sanity only; the proof is replay spike-baseline) ====="
for n in spine01 spine02 leaf01 leaf02; do
    c=$(container_of "$n")
    echo "--- $n: BGP_NEIGHBOR keys"
    node_run "$c" "sudo redis-cli -n 4 --raw KEYS 'BGP_NEIGHBOR|*' | sort" 2>/dev/null || true
    echo "--- $n: locator rows (expect none)"
    node_run "$c" "sudo redis-cli -n 4 --raw KEYS 'SRV6_MY_LOCATORS*' | sort" 2>/dev/null || true
done
echo "seed-restore done"
