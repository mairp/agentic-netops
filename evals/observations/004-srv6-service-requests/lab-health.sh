#!/usr/bin/env bash
# specstride --health-cmd for the 004 SONiC lab: exit 0 when the probe sees no
# infra fault (units, VRF wedge, BGP sessions vs the seed/as-built state, host).
exec python3 "$(dirname "$(readlink -f "$0")")/probe.py" --health
