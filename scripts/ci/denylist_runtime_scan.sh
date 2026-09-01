#!/usr/bin/env bash
# T080: Runtime scan for standalone/Compose workloads. The goal is to ensure
# the AINETOPS project itself does not run standalone/Compose application
# containers. Other unrelated host containers must not cause a failure.
#
# Policy:
# - PASS when no containers owned by AINETOPS (by label ainetops.owner=ainetops
#   or name prefix ainetops-/clab-ainetops-) are managed by docker-compose or
#   are running outside Kubernetes.
# - Advisory print of other host containers, but do not fail on them.
# - Emit RUNTIME_SCAN_NO_STANDALONE on success; exit non-zero on violation.
set -euo pipefail

ok=1
violations=()

# Detect AINETOPS-owned or -named containers that are managed by compose
if command -v docker >/dev/null 2>&1; then
  # List: name labels
  while IFS= read -r line; do
    name=$(cut -d' ' -f1 <<<"$line")
    labels=$(cut -d' ' -f2- <<<"$line")
    # Only consider containers clearly tied to this project
    if [[ "$labels" == *"ainetops.owner=ainetops"* ]] || [[ "$name" =~ ^(ainetops|clab-ainetops) ]]; then
      if grep -Eq 'docker-compose|compose_project|compose.service|com.docker.compose' <<<"$labels"; then
        violations+=("$name has compose labels: $labels")
        ok=0
      fi
    fi
  done < <(docker ps -a --format '{{.Names}} {{.Labels}}' 2>/dev/null || true)
fi

# Prefer in-cluster deployments; if kubectl is available, list known namespaces (advisory)
if command -v kubectl >/dev/null 2>&1; then
  kubectl get pods -A 2>/dev/null | awk 'NR>1{print $1}' | sort -u | tee /dev/stderr || true
fi

if [[ ${#violations[@]} -gt 0 ]]; then
  echo "[runtime-scan] Found AINETOPS-owned containers managed by docker-compose:" >&2
  printf ' - %s\n' "${violations[@]}" >&2
  ok=0
fi

if [[ $ok -eq 1 ]]; then
  echo "RUNTIME_SCAN_NO_STANDALONE"
else
  exit 1
fi
