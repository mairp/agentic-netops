#!/usr/bin/env bash
# Stage A2: re-record the ifindex-fixed vpn proofs, restore rollback-last
# order, record the vpn replay receipt, then re-record evpn3+evpn2+steering.
cd /root/agentic-netops || exit 9
scripts/proof.sh spike-vpn-readback-leaf01 -- bash scripts/spike/vpn-readback.sh leaf01
echo "##### RC-readback01=$?"
scripts/proof.sh spike-vpn-readback-leaf02 -- bash scripts/spike/vpn-readback.sh leaf02
echo "##### RC-readback02=$?"
scripts/proof.sh spike-vpn-clients -- bash scripts/spike/vpn-clients.sh
echo "##### RC-clients=$?"
scripts/proof.sh spike-vpn-rollback -- bash scripts/spike/vpn-rollback.sh
echo "##### RC-rollback=$?"
if grep -q "@if[0-9]" .wiggum/features/004-srv6-service-requests/gates/proofs/spike-vpn-readback-leaf01.out .wiggum/features/004-srv6-service-requests/gates/proofs/spike-vpn-readback-leaf02.out .wiggum/features/004-srv6-service-requests/gates/proofs/spike-vpn-clients.out; then
  echo "IFINDEX-STILL-LEAKING-ABORT"; exit 3
fi
echo "IFINDEX-CLEAN-PROCEED"
scripts/proof.sh spike-rerun-vpn -- scripts/proof.sh replay spike-vpn
rc=$?
echo "RERUN-VPN-RC=$rc"
if grep -q "^differ:" .wiggum/features/004-srv6-service-requests/gates/proofs/spike-rerun-vpn.out; then
  echo "RERUN-VPN-DIFFER-ABORT"; exit 3
fi
echo "RERUN-VPN-CLEAN-PROCEED"
/tmp/g3/rerecord-rest.sh
echo "STAGEA2-DONE rc=$?"
