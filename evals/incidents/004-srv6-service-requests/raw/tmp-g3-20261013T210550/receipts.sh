#!/usr/bin/env bash
# Pass-14 receipt recording: T106 (vpn), T107 (evpn3), T108 (evpn2),
# T109 (steering), T105 (baseline after seed-restore). Fail-fast on any
# differ; every step logged. Run from /root/agentic-netops.
cd /root/agentic-netops || exit 9
P=.wiggum/features/004-srv6-service-requests/gates/proofs

receipt() { # $1 receipt name, $2 group prefix
  echo "##### RECEIPT $1 (replay $2) $(date +%H:%M:%S)"
  scripts/proof.sh "$1" -- scripts/proof.sh replay "$2"
  rc=$?
  echo "##### RC-$1=$rc"
  if [ "$rc" -ne 0 ] || grep -q "^differ:" "$P/$1.out" 2>/dev/null; then
    echo "##### $1 DIFFERS-ABORT"
    exit 3
  fi
}

receipt spike-rerun-vpn spike-vpn      || exit 3
receipt spike-rerun-evpn3 spike-evpn3  || exit 3
receipt spike-rerun-evpn2 spike-evpn2  || exit 3
receipt spike-rerun-steering spike-steering || exit 3

echo "##### SEED-RESTORE $(date +%H:%M:%S)"
bash scripts/spike/seed-restore.sh
src=$?
echo "##### SEED-RESTORE-RC=$src"
if [ "$src" -ne 0 ]; then echo "##### SEED-RESTORE-ABORT"; exit 4; fi

echo "##### DRY replay spike-baseline $(date +%H:%M:%S)"
scripts/proof.sh replay spike-baseline
brc=$?
echo "##### DRY-BASELINE-RC=$brc"
if [ "$brc" -ne 0 ]; then echo "##### BASELINE-DIFFER-ABORT"; exit 5; fi

receipt spike-rerun-baseline spike-baseline || exit 3
echo "##### ALL-RECEIPTS-DONE $(date +%H:%M:%S)"
