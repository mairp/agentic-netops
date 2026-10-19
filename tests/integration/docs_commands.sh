#!/usr/bin/env bash
# T577 [US8] Documentation command runner (12-11, q16).
#
# Extracts the fenced commands that the documentation TAGS for verification
# and runs each one on the live lab, failing on the FIRST whose output does
# not contain the expected text beside it (SC-017: the docs' commands stay
# true against the running system).
#
# Tag convention (used by T578-T586):
#
#   ```bash verify="srv6-ip-vrf-vpn,Ready"
#   kubectl -n agentic-netops-intent get srv6service
#   ```
#
# The verify attribute lists the substrings (comma-separated) that the
# command's combined output must contain; several may be listed when one
# marker is not enough to prove the sentence the command illustrates. Fenced
# blocks without a verify tag are documentation only and are not run.
#
# Switch reads inside doc commands go through the node_exec helpers
# (node_run/node_sudo), which this script exports for the child shells —
# never docker exec into a switch (§8.7). Clients stay docker exec + sh -c.
#
# Usage:
#   docs_commands.sh [--list] FILE [FILE...]
#     --list   print file:line and the expected substrings, run nothing
# Exit 0 only when every tagged command ran and returned its markers.
set -u

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/integration/lib/node_exec.sh
source "${ROOT_DIR}/tests/integration/lib/node_exec.sh"
export -f node_run node_run_i node_sudo node_is_vm node_guest_addr 2>/dev/null || true

die()  { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "PASS: $*"; }

LIST_ONLY=0
FILES=()
for a in "$@"; do
  case "$a" in
    --list) LIST_ONLY=1 ;;
    -*) die "unknown flag: $a" ;;
    *) FILES+=("$a") ;;
  esac
done
(( ${#FILES[@]} )) || die "usage: $0 [--list] FILE [FILE...]"

# Precondition: the lab must be up for anything live (standard SKIP-LIVE
# marker, matching evpn_srv6_suite.sh / srv6_failover_path_change.sh).
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^clab-agentic-netops-fabric-leaf01$'; then
  echo "SKIP-LIVE: docs command runner requires a provisioned lab; capability gate (scripts/lib/qualify.sh) is the source of truth"
  exit 0
fi

# extract_tags <files...> -> "path<TAB>first-line<TAB>expected<TAB>base64(body)"
extract_tags() {
  python3 - "$@" <<'PY'
import base64, re, sys
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        print(f"FAIL: cannot read {path}: {e}", file=sys.stderr)
        raise SystemExit(2)
    opener = re.compile(r'^\s*```[^\n]*\bverify=(["\'])(.+?)\1')
    closer = re.compile(r'^\s*```\s*$')
    i = 0
    while i < len(lines):
        m = opener.match(lines[i])
        if not m:
            i += 1
            continue
        expected = m.group(2).strip()
        body, j = [], i + 1
        while j < len(lines) and not closer.match(lines[j]):
            body.append(lines[j])
            j += 1
        if j >= len(lines):
            print(f"FAIL: {path}:{i+1}: unterminated fenced block", file=sys.stderr)
            raise SystemExit(2)
        print(f"{path}\t{i+2}\t{expected}\t" + base64.b64encode("\n".join(body).encode()).decode())
        i = j + 1
PY
}

declare -a TAGGED=()
mapfile -t TAGGED < <(extract_tags "${FILES[@]}")
(( ${#TAGGED[@]} )) || die "no verify-tagged fenced commands found in: ${FILES[*]}"

total=0
while IFS=$'\t' read -r path lineno expected body64; do
  [[ -n "$path" ]] || continue
  total=$((total + 1))
  where="${path}:${lineno}"
  if [[ "$LIST_ONLY" == 1 ]]; then
    echo "WOULD-RUN: ${where} expects: ${expected}"
    continue
  fi
  body=$(printf '%s' "$body64" | base64 -d)
  echo "--- [${total}] ${where}"
  out=$(cd "$ROOT_DIR" && timeout 180 bash -c "$body" 2>&1)
  rc=$?
  if (( rc != 0 )); then
    echo "--- captured output (rc=${rc}):"
    sed -n '1,15p' <<<"$out"
    die "${where} exited ${rc}"
  fi
  IFS=',' read -ra wants <<<"$expected"
  for w in "${wants[@]}"; do
    w=$(printf '%s' "$w" | sed 's/^ *//;s/ *$//')
    [[ -n "$w" ]] || continue
    if ! grep -qF -- "$w" <<<"$out"; then
      echo "--- captured output:"
      sed -n '1,15p' <<<"$out"
      die "${where}: output does not contain the expected text beside it: '${w}'"
    fi
  done
  ok "${where} returned everything it promises (${expected})"
done < <(printf '%s\n' "${TAGGED[@]}")

[[ "$LIST_ONLY" == 1 ]] && exit 0
echo "DOCS_COMMANDS_OK (${total} tagged commands verified)"
