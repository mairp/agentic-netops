#!/usr/bin/env bash
# Security audit (T073, FR-015): scan RBAC verbs/scopes, Secret use, TLS validation,
# image privileges, Docker/KVM trust boundaries, Grafana plugin provenance,
# anonymous access/default credentials, and log/status redaction.
# Emits a human-readable report and exits non-zero on critical findings.
set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT_DIR"

RED="\e[31m"; YEL="\e[33m"; GRN="\e[32m"; NC="\e[0m"
fail=0

section() { echo -e "\n=== $1 ==="; }
ok() { echo -e "${GRN}OK${NC}: $1"; }
warn() { echo -e "${YEL}WARN${NC}: $1"; }
err() { echo -e "${RED}ERROR${NC}: $1"; fail=1; }

# Helper: rg wrapper falling back to grep. When ripgrep is unavailable,
# translate "\\s" to POSIX [[:space:]] so whitespace classes still match.
search_ci() {
  local pattern="$1"; shift
  local pat_grep="${pattern//\\s/[[:space:]]}"
  if command -v rg >/dev/null 2>&1; then
    rg -n --hidden --no-ignore -g '!*/.git/*' -e "$pattern" "$@" || true
  else
    grep -RIn --exclude-dir=.git -E "$pat_grep" "$@" || true
  fi
}

section "RBAC minimal verbs/scopes"
rbac_dirs=(config/rbac deploy/rbac)
# Match list form: verbs: ["*"] or value form: - "*"
found_wildcards=$(search_ci '\\bverbs\\s*:\\s*(\\[[^]]*\\*[^]]*\\]|$)|^-\\s*\"?\*\"?$' "${rbac_dirs[@]}")
cluster_admin_bindings=$(search_ci 'cluster-admin' config/rbac deploy/rbac)
if [[ -n "$found_wildcards" ]]; then err "Wildcard verbs detected:\n$found_wildcards"; else ok "No wildcard verbs in RBAC"; fi
if [[ -n "$cluster_admin_bindings" ]]; then err "cluster-admin binding detected:\n$cluster_admin_bindings"; else ok "No cluster-admin bindings in Agentic NetOps manifests"; fi

section "Secret use"
static_secret_data=$(search_ci '^\s*(data|stringData):' deploy/rbac | grep -vE 'secret-generator|example|test' || true)
if [[ -n "$static_secret_data" ]]; then warn "Potential static Secret content present (should be generated):\n$static_secret_data"; else ok "No static Secret content checked into deploy/rbac"; fi
gen_jobs=$(ls -1 deploy/rbac/secret-generator-job.yaml 2>/dev/null || true)
if [[ -n "$gen_jobs" ]]; then ok "Secret generator job present: deploy/rbac/secret-generator-job.yaml"; else err "Missing secret generator job under deploy/rbac"; fi

section "TLS validation for gNMIc"
if [[ -f deploy/gnmi/gnmic.yaml ]]; then
  if grep -nE "skip-verify:\\s*false" deploy/gnmi/gnmic.yaml >/dev/null; then ok "gNMIc TLS skip-verify=false"; else err "gNMIc skip-verify not set to false"; fi
  if search_ci 'secretKeyRef:.*(tls-ca|tls-cert|tls-key)' deploy/gnmi/gnmic.yaml >/dev/null; then ok "gNMIc references tls-ca/tls-cert/tls-key via Secret"; else err "gNMIc TLS secretKeyRefs not found"; fi
else warn "deploy/gnmi/gnmic.yaml not found"; fi

section "Image privileges (Dockerfiles/manifests)"
bad_user=$(search_ci '^\s*USER\s+root\b' cmd | grep -v '/vendor/' || true)
if [[ -n "$bad_user" ]]; then err "Some Dockerfiles set USER root:\n$bad_user"; else ok "Controller Dockerfiles do not run as root"; fi
distroless=$(search_ci '(gcr\.io/distroless|distroless)' cmd || true)
if [[ -n "$distroless" ]]; then ok "Distroless base images in use"; else warn "Distroless base image not detected; verify minimal base manually"; fi
manifest_nonroot=$(search_ci 'runAsNonRoot:\\s*true' deploy || true)
if [[ -n "$manifest_nonroot" ]]; then ok "Kubernetes manifests set runAsNonRoot where applicable"; else warn "runAsNonRoot not explicitly set in manifests"; fi

section "Docker/KVM trust boundaries"
if grep -nE "preflight::kvm_check|kvm_check" scripts/lib/preflight.sh >/dev/null 2>&1; then ok "KVM check present in preflight for sonic-vm"; else warn "KVM check not found in preflight"; fi

section "Grafana plugin provenance and auth"
if [[ -f deploy/observability/grafana.yaml ]]; then
  if search_ci 'GF_AUTH_ANONYMOUS_ENABLED:\\s*"?false"?' deploy/observability/grafana.yaml >/dev/null; then ok "Grafana anonymous disabled"; else err "Grafana anonymous may be enabled"; fi
  plugin_install=$(search_ci 'name: GF_INSTALL_PLUGINS' deploy/observability/grafana.yaml || true)
  if [[ -n "$plugin_install" ]]; then err "Grafana third-party plugin install present (no unpinned plugins allowed)"; else ok "Grafana installs no third-party plugins (built-in panels only)"; fi
  if grep -q 'grafana_flow_plugin:.*@sha256:[a-f0-9]\{64\}' versions.lock.yaml 2>/dev/null; then ok "Grafana flow visualization pin recorded (presentation reference, FR-032)"; else err "Grafana flow visualization pin missing from versions.lock.yaml"; fi
else warn "deploy/observability/grafana.yaml not found"; fi

section "Anonymous access/default credentials"
admin_secret_job=$(ls -1 deploy/observability/grafana-secret-generator-job.yaml 2>/dev/null || true)
if [[ -n "$admin_secret_job" ]]; then ok "Grafana secret generator job present"; else warn "Grafana secret generator job not found"; fi

section "Log/status redaction"
secret_logs=$(search_ci '\\blog\\w*\\(.*(secret|password|token).*\\)' controllers || true)
if [[ -n "$secret_logs" ]]; then warn "Potential secret logging sites:\n$secret_logs"; else ok "No obvious secret value logging patterns found"; fi

if [[ "$fail" -ne 0 ]]; then
  echo -e "\nSecurity audit completed with errors (FR-015)" >&2
  exit 1
fi

echo "SECURITY_AUDIT_OK"
