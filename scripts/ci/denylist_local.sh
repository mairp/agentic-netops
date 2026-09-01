#!/usr/bin/env bash
# Run the same deny-list policy as CI locally (T074a)
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PROOFS_DIR="$ROOT_DIR/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs"
mkdir -p "$PROOFS_DIR"
export PATH="$PATH:/usr/local/bin"

# Prefer shared policy script (kept in-repo for stability)
if [[ -x "$ROOT_DIR/scripts/ci/denylist_policy.sh" ]]; then
  "$ROOT_DIR/scripts/ci/denylist_policy.sh"
  exit $?
fi

# Fallback: extract the workflow run body
awk '/^\s*run: \|/{f=1;next} f{print} ' "$ROOT_DIR/.github/workflows/denylist.yml" \
  | bash -euo pipefail 2>&1 | tee "$PROOFS_DIR/denylist.run.log"
