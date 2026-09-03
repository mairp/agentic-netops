#!/usr/bin/env bash
# Shared bootstrap: materialize local ./secrets/{ca.crt,gnmi.crt,gnmi.key} and
# GNMI_USER/GNMI_PASS from the in-cluster generator Secrets so gNMI qualification
# and fabric verification suites can run against the lab (T076 readiness stage).
# Usage: source scripts/lib/lab_secrets.sh && lab_secrets::ensure [context]
# shellcheck shell=bash

lab_secrets::ensure() {
  local ctx="${1:-}"
  local ca=${GNMI_CACERT:-./secrets/ca.crt}
  local crt=${GNMI_CERT:-./secrets/gnmi.crt}
  local key=${GNMI_KEY:-./secrets/gnmi.key}
  local kargs=()
  [[ -n "$ctx" ]] && kargs=(--context "$ctx")
  if [[ -f "$ca" && -f "$crt" && -f "$key" && -n "${GNMI_USER:-}" && -n "${GNMI_PASS:-}" ]]; then
    return 0
  fi
  command -v kubectl >/dev/null 2>&1 || { echo "[lab-secrets] kubectl unavailable; using defaults" >&2; return 0; }
  mkdir -p ./secrets
  # T079 fix: never silently succeed with missing material. Wait briefly for the
  # generator job/secrets (created during provision), then verify the files.
  local try
  for try in 1 2 3 4 5 6; do
    if kubectl "${kargs[@]}" -n agentic-netops-system get secret gnmi-lab-tls >/dev/null 2>&1; then
      break
    fi
    kubectl "${kargs[@]}" -n agentic-netops-system wait --for=condition=complete job/agentic-netops-secret-generator --timeout=30s >/dev/null 2>&1 || true
    sleep 2
  done
  if kubectl "${kargs[@]}" -n agentic-netops-system get secret gnmi-lab-creds >/dev/null 2>&1; then
    GNMI_USER=${GNMI_USER:-$(kubectl "${kargs[@]}" -n agentic-netops-system get secret gnmi-lab-creds -o jsonpath='{.data.username}' | base64 -d)}
    GNMI_PASS=${GNMI_PASS:-$(kubectl "${kargs[@]}" -n agentic-netops-system get secret gnmi-lab-creds -o jsonpath='{.data.password}' | base64 -d)}
    export GNMI_USER GNMI_PASS
  fi
  if kubectl "${kargs[@]}" -n agentic-netops-system get secret gnmi-lab-tls >/dev/null 2>&1; then
    kubectl "${kargs[@]}" -n agentic-netops-system get secret gnmi-lab-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$ca"
    kubectl "${kargs[@]}" -n agentic-netops-system get secret gnmi-lab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$crt"
    kubectl "${kargs[@]}" -n agentic-netops-system get secret gnmi-lab-tls -o jsonpath='{.data.tls\.key}' | base64 -d > "$key"
  fi
  if [[ ! -s "$ca" || ! -s "$crt" || ! -s "$key" ]]; then
    echo "[lab-secrets] FAILED to materialize ${ca} ${crt} ${key} from gnmi-lab-tls" >&2
    return 1
  fi
  return 0
}
