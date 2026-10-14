#!/usr/bin/env bash
# Stage B: restore the exact provision seed, verify the baseline replay is
# byte-clean, then record the T105 receipt.
cd /root/agentic-netops || exit 9
echo "##### seed-restore"
bash scripts/spike/seed-restore.sh
echo "##### SEED-RESTORE-RC=$?"
echo "##### dry replay spike-baseline"
scripts/proof.sh replay spike-baseline
rc=$?
echo "##### DRY-BASELINE-RC=$rc"
if [ "$rc" -ne 0 ]; then echo "BASELINE-DIFFER-ABORT"; exit 3; fi
echo "##### record spike-rerun-baseline"
scripts/proof.sh spike-rerun-baseline -- scripts/proof.sh replay spike-baseline
echo "##### RERUN-BASELINE-RC=$?"
echo "STAGEB-DONE"
