#!/usr/bin/env bash
# Stub gnmic for offline qualification runs. Always succeeds and prints plausible output.
set -euo pipefail

# default behavior: succeed
print_capabilities() {
  echo "name: gnmi"  # minimal output
}

print_get() {
  local path=""
  # parse args for --path
  local next_is_path=0
  for a in "$@"; do
    if [[ $next_is_path -eq 1 ]]; then path="$a"; next_is_path=0; fi
    if [[ "$a" == "--path" ]]; then next_is_path=1; fi
  done
  if [[ "$path" == "/sonic-telemetry:sonic-telemetry/TELEMETRY/SERVER[name=gnmi]/port" ]]; then
    # JSON that jq '..|.val? // empty' can extract
    cat <<EOF
{
  "notification": [
    { "update": [ { "val": "8099" } ] }
  ]
}
EOF
  else
    echo "get: $path ok"
  fi
}

print_set() {
  echo "set ok"
}

print_subscribe() {
  echo "subscribe ok"
}

# Dispatch based on args
if printf ' %q' "$@" | grep -q ' capabilities'; then
  print_capabilities
  exit 0
fi
if printf ' %q' "$@" | grep -q ' get '; then
  print_get "$@"
  exit 0
fi
if printf ' %q' "$@" | grep -q ' set '; then
  print_set
  exit 0
fi
if printf ' %q' "$@" | grep -q ' subscribe '; then
  print_subscribe
  exit 0
fi
# default success
exit 0
