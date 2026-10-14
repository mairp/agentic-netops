#!/usr/bin/env bash
# mixture-of-loops-generated: renderer=1.0 contract-sha256=33838c9922fb50ef433db56b755a512ffdfc740d18536dbc37ee0efe2da19a13
# generated-content-sha256: d0f8fc2e84d906d3770a1562c30788089b1f078e6a5ac088b964a64a6bfe15ab
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/.mixture-of-loops/generated/004-srv6-service-requests/33838c9922fb50ef433d"
exec python3 "$BUNDLE_DIR/runtime.py" \
  --contract "$BUNDLE_DIR/launch-contract.json" \
  --launch-dir "$SCRIPT_DIR" "$@"
