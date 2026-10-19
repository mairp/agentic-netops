#!/usr/bin/env bash
# Proof p9-goldens (plan 9-08): the Go intent-contract battery for US4 —
# `go test ./tests/unit/...` green, with the SRv6 goldens (srv6_ip_vrf_vpn,
# srv6_ip_vrf_evpn, srv6_mac_vrf_evpn), the V1-V8 refusal rules and every
# pre-existing golden/equivalence test unchanged (T431-T454).
#
# Declared to the verification gate by SCRIPT PATH, never wrapped in
# `bash -c` (see run-q10-baseline.sh for the gate's exec convention).
# Build flags mirror make build-intent-translator (vendored, static).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
export GOFLAGS="-buildvcs=false"
go test ./tests/unit/...
