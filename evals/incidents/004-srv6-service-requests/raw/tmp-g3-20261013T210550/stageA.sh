#!/usr/bin/env bash
# Stage A: record the vpn replay receipt; if clean, re-record evpn3+evpn2+steering groups.
cd /root/agentic-netops || exit 9
scripts/proof.sh spike-rerun-vpn -- scripts/proof.sh replay spike-vpn
rc=$?
echo "RERUN-VPN-RC=$rc"
if grep -q "^differ:" .wiggum/features/004-srv6-service-requests/gates/proofs/spike-rerun-vpn.out; then
  echo "RERUN-VPN-DIFFER-ABORT"
  exit 3
fi
echo "RERUN-VPN-CLEAN-PROCEED"
/tmp/g3/rerecord-rest.sh
echo "STAGEA-DONE rc=$?"
