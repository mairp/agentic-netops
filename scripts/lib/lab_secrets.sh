#!/usr/bin/env bash
# Shared bootstrap: materialize the local trust anchor ./secrets/ca.crt and the
# generated GNMI_USER/GNMI_PASS from the in-cluster generator Secrets so gNMI
# qualification and fabric verification suites can run against the lab.
#
# The SR Linux gNMI server does not require a client certificate: it presents a
# containerlab-signed server certificate and authenticates the caller with
# username/password. So ca.crt is the only material a client MUST have, and it
# is the only one this helper fails on. tls.crt/tls.key are still materialized
# when the generator Secret carries them, because the Secret's shape is API for
# the executor and the observability stack, but their absence is not an error.
#
# Usage: source scripts/lib/lab_secrets.sh && lab_secrets::ensure [context]
# shellcheck shell=bash

lab_secrets::ensure() {
  local ctx="${1:-}"
  local ca=${GNMI_CACERT:-./secrets/ca.crt}
  local crt=${GNMI_CERT:-./secrets/tls.crt}
  local key=${GNMI_KEY:-./secrets/tls.key}
  local kargs=()
  [[ -n "$ctx" ]] && kargs=(--context "$ctx")
  if [[ -s "$ca" && -n "${GNMI_USER:-}" && -n "${GNMI_PASS:-}" ]]; then
    return 0
  fi
  command -v kubectl >/dev/null 2>&1 || { echo "[lab-secrets] kubectl unavailable; using defaults" >&2; return 0; }
  mkdir -p ./secrets
  # Never silently succeed with missing material. Wait briefly for the generator
  # job/secrets (created during provision), then verify the files.
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
    # Optional client material: keep it when present, do not invent it when absent.
    kubectl "${kargs[@]}" -n agentic-netops-system get secret gnmi-lab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$crt" 2>/dev/null || true
    kubectl "${kargs[@]}" -n agentic-netops-system get secret gnmi-lab-tls -o jsonpath='{.data.tls\.key}' | base64 -d > "$key" 2>/dev/null || true
    [[ -s "$crt" ]] || rm -f "$crt"
    [[ -s "$key" ]] || rm -f "$key"
  fi
  if [[ ! -s "$ca" ]]; then
    echo "[lab-secrets] FAILED to materialize ${ca} from gnmi-lab-tls (key ca.crt); scripts/lib/containerlab.sh bootstrap publishes the containerlab CA into that Secret" >&2
    return 1
  fi
  if [[ -z "${GNMI_USER:-}" || -z "${GNMI_PASS:-}" ]]; then
    echo "[lab-secrets] FAILED to read the generated gNMI credentials from Secret gnmi-lab-creds" >&2
    return 1
  fi
  return 0
}
