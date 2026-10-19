#!/usr/bin/env bash
# configure-fabric-bgp.sh — the fabric-wide hook containerlab.sh calls after
# every per-node bootstrap ("configuring underlay BGP + EVPN across the
# fabric", clab::bootstrap). The sonic-vm implementation lives in
# configure-fabric.sh next to this file (identity, underlay BGP, the
# kernel+SAI EVPN overlay baseline with its reload re-asserts and adoption
# gates); this shim exists so the hook NAME matches the convention the sonic-vs
# profile established (clab::bootstrap tests for configure-fabric-bgp.sh
# exactly), while keeping the real script's path stable for the phase-4
# evidence citations.
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$DIR/configure-fabric.sh" "$@"
