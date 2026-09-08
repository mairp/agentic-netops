#!/usr/bin/env bash
# Minimal .env loader for the provisioning scripts, mirroring python-dotenv's
# default semantics: KEY=VALUE lines, `#` comments, optional surrounding quotes,
# and variables already present in the environment are NOT overridden (an
# exported shell variable always wins over the file). The agent tier's Python
# side loads the same file through python-dotenv (agents/config/config.py), so
# one .env at the repo root serves both the operator's shell and a local run.
#
# Usage: dotenv::load [path]   (default: <repo root>/.env; AGENTIC_NETOPS_ENV_FILE overrides)

dotenv::load() {
  local file="${1:-${AGENTIC_NETOPS_ENV_FILE:-}}"
  if [[ -z "$file" ]]; then
    file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/.env"
  fi
  [[ -f "$file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"          # ltrim
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"              # rtrim key
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="${value#"${value%%[![:space:]]*}"}"
    if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    else
      value="${value%%[[:space:]]#*}"                 # strip trailing comment
      value="${value%"${value##*[![:space:]]}"}"
    fi
    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done < "$file"
  # shellcheck disable=SC2034  # read by callers (intent_tier.sh logs the path)
  DOTENV_LOADED_FROM="$file"
}
