#!/usr/bin/env bash
# Strict shell reusable preflight checks (Phase 1)
set -euo pipefail

preflight::die() { echo "[preflight] ERROR: $*" >&2; exit 1; }
preflight::warn() { echo "[preflight] WARN: $*" >&2; }

preflight::require_cmd() {
  local cmd=$1; command -v "$cmd" >/dev/null 2>&1 || preflight::die "missing required command: $cmd"
}

preflight::check_versions_lock() {
  local root; root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
  local f="$root/versions.lock.yaml"
  [[ -f "$f" ]] || preflight::die "versions.lock.yaml not found at $f"
  # Reject 'latest' and floating refs quickly; make verify-pins will perform full validation
  if grep -nEi '\blatest\b|\bmain\b|\bmaster\b|\bHEAD\b' "$f" >/dev/null; then
    preflight::die "versions.lock.yaml contains floating refs (latest/main/master/HEAD)."
  fi
}

preflight::host_resources() {
  # Minimal CPU/RAM/disk checks; allow override via env for CI
  local min_cpu=${AINETOPS_MIN_CPU:-4}
  local min_mem_mb=${AINETOPS_MIN_MEM_MB:-8192}
  local min_disk_mb=${AINETOPS_MIN_DISK_MB:-20480}
  # Best-effort checks; platform-specific commands may vary
  local cores mem_kb avail_kb
  cores=$(getconf _NPROCESSORS_ONLN || echo 1)
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  avail_kb=$(df -Pm . 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
  (( cores >= min_cpu )) || preflight::die "CPU cores $cores < required $min_cpu"
  (( mem_kb/1024 >= min_mem_mb )) || preflight::die "Memory $((${mem_kb}/1024))MB < required ${min_mem_mb}MB"
  (( avail_kb >= min_disk_mb )) || preflight::die "Disk ${avail_kb}MB free < required ${min_disk_mb}MB"
}

# Phase 10 — additional headroom checks when installing the intent tier.
# When provision.sh is invoked with --with-intent-tier it exports
# AINETOPS_WITH_INTENT_TIER=true; enforce extra CPU/memory/storage headroom
# so tier pods do not evict or starve feature-001 workloads (NFR-007).
preflight::intent_tier_headroom() {
  local with="${AINETOPS_WITH_INTENT_TIER:-false}"
  if [[ "$with" != "true" ]]; then
    return 0
  fi
  local base_cpu=${AINETOPS_MIN_CPU:-4}
  local base_mem_mb=${AINETOPS_MIN_MEM_MB:-8192}
  local base_disk_mb=${AINETOPS_MIN_DISK_MB:-20480}
  local add_cpu=${AINETOPS_INTENT_TIER_CPU_HEADROOM_CORES:-2}
  local add_mem_mb=${AINETOPS_INTENT_TIER_MEM_HEADROOM_MB:-4096}
  local add_pvc_mb=${AINETOPS_INTENT_TIER_PVC_TOTAL_MB:-6144}
  local req_cpu=$(( base_cpu + add_cpu ))
  local req_mem_mb=$(( base_mem_mb + add_mem_mb ))
  local req_disk_mb=$(( base_disk_mb + add_pvc_mb ))
  local cores mem_kb avail_mb
  cores=$(getconf _NPROCESSORS_ONLN || echo 1)
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  avail_mb=$(df -Pm . 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
  (( cores >= req_cpu )) || preflight::die "CPU cores $cores < required $req_cpu for --with-intent-tier"
  (( mem_kb/1024 >= req_mem_mb )) || preflight::die "Memory $((${mem_kb}/1024))MB < required ${req_mem_mb}MB for --with-intent-tier"
  (( avail_mb >= req_disk_mb )) || preflight::die "Disk ${avail_mb}MB free < required ${req_disk_mb}MB for intent tier PVCs"
  preflight::warn "intent-tier headroom satisfied (CPU>=$req_cpu, Mem>=$req_mem_mb MB, Disk free>=$req_disk_mb MB)"
}


preflight::runtime_privileges() {
  # Require Docker-compatible runtime and privileges for Kind/containerlab
  preflight::require_cmd docker
  if ! docker info >/dev/null 2>&1; then
    preflight::die "docker daemon not reachable"
  fi
}

# Utility: IPv4 dotted-quad to integer
preflight::ip2int() {
  local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

# Utility: derive [start,end] integer range from CIDR
preflight::cidr_range() {
  local cidr=$1 ip=${1%/*} mask=${1#*/}
  local ipn; ipn=$(preflight::ip2int "$ip")
  local maskn=$(( 0xFFFFFFFF << (32-mask) & 0xFFFFFFFF ))
  local start=$(( ipn & maskn ))
  local end=$(( start | (~maskn & 0xFFFFFFFF) ))
  echo "$start $end"
}

# Return 0 (overlap) or 1 (disjoint)
preflight::ranges_overlap() {
  local a1=$1 a2=$2 b1=$3 b2=$4
  if (( a1 <= b2 && b1 <= a2 )); then return 0; else return 1; fi
}

preflight::address_conflicts() {
  # Ensure management network CIDR does not overlap pod/service CIDRs
  local mgmt_cidr=${AINETOPS_MGMT_CIDR:-172.31.0.0/16}
  local pod_cidr=${AINETOPS_POD_CIDR:-10.244.0.0/16}
  local svc_cidr=${AINETOPS_SERVICE_CIDR:-10.96.0.0/12}
  read -r m1 m2 < <(preflight::cidr_range "$mgmt_cidr")
  read -r p1 p2 < <(preflight::cidr_range "$pod_cidr")
  read -r s1 s2 < <(preflight::cidr_range "$svc_cidr")
  if preflight::ranges_overlap "$m1" "$m2" "$p1" "$p2"; then
    preflight::die "Management CIDR $mgmt_cidr overlaps Pod CIDR $pod_cidr"
  fi
  if preflight::ranges_overlap "$m1" "$m2" "$s1" "$s2"; then
    preflight::die "Management CIDR $mgmt_cidr overlaps Service CIDR $svc_cidr"
  fi
}

preflight::mtu() {
  # Verify host MTU accommodates VXLAN overhead (> 1500 suggested); warn only in Phase 1
  local maxmtu=0
  while read -r mtu; do (( mtu > maxmtu )) && maxmtu=$mtu; done < <(ip -o link 2>/dev/null | awk -F'mtu ' '{print $2}' | awk '{print $1}')
  if (( maxmtu < 1500 )); then preflight::warn "maximum host MTU $maxmtu < 1500; VXLAN overhead may break traffic"; fi
}

preflight::kvm_check() {
  local profile=${AINETOPS_PROFILE:-sonic-vs}
  if [[ "$profile" == "sonic-vm" ]]; then
    # Require KVM when sonic-vm profile selected
    [[ -e /dev/kvm ]] || preflight::die "/dev/kvm not present for sonic-vm profile"
  fi
}

# Extract value from versions.lock.yaml given a top-level section and key
preflight::yaml_value() {
  local section=$1 key=$2 file; file=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/versions.lock.yaml
  awk -v sec="$section" -v key="$key" '
    $0 ~ "^"sec":\s*$" {inside=1; next}
    inside && $0 ~ "^[^[:space:]]" {inside=0}
    inside && $0 ~ "^[[:space:]]+"key":" {
      val=$0; sub(/^[^:]*:[[:space:]]*/, "", val); gsub(/\"/, "", val); print val; exit
    }
  ' "$file"
}

preflight::tool_versions() {
  # Verify host tool versions match pins in versions.lock.yaml
  local soft=${AINETOPS_SOFT_TOOLCHECK:-false}

  # In soft mode, warn instead of die on missing tools or version mismatches (CI/minimal env)
  local tools=(kind kubectl helm containerlab jq curl)
  for c in "${tools[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      if [[ "$soft" == "true" ]]; then preflight::warn "missing tool: $c (soft mode)"; else preflight::die "missing required command: $c"; fi
    fi
  done

  local kind_pin kubectl_pin helm_pin clab_pin
  kind_pin=$(preflight::yaml_value kind binary)
  # Prefer host_tools.kubectl if present, else fall back to kubernetes.kubernetes
  kubectl_pin=$(preflight::yaml_value host_tools kubectl)
  if [[ -z "${kubectl_pin}" ]]; then kubectl_pin=$(preflight::yaml_value kubernetes kubernetes); fi
  helm_pin=$(preflight::yaml_value host_tools helm)
  clab_pin=$(preflight::yaml_value containerlab version)

  [[ -n "$kind_pin" ]] || preflight::die "missing kind.binary pin in versions.lock.yaml"
  [[ -n "$kubectl_pin" ]] || preflight::die "missing host_tools.kubectl or kubernetes.kubernetes pin in versions.lock.yaml"
  [[ -n "$helm_pin" ]] || preflight::die "missing host_tools.helm pin in versions.lock.yaml"
  [[ -n "$clab_pin" ]] || preflight::die "missing containerlab.version pin in versions.lock.yaml"

  # kind
  if command -v kind >/dev/null 2>&1; then
    local kind_ver; kind_ver=$(kind version 2>/dev/null | awk '{print $2}') || true
    if [[ "$kind_ver" != "$kind_pin" ]]; then
      if [[ "$soft" == "true" ]]; then preflight::warn "kind version $kind_ver != pinned $kind_pin (soft mode)"; else preflight::die "kind version $kind_ver != pinned $kind_pin"; fi
    fi
  fi

  # kubectl
  if command -v kubectl >/dev/null 2>&1; then
    local kubectl_ver; kubectl_ver=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' || true)
    if [[ "$kubectl_ver" != "$kubectl_pin" ]]; then
      if [[ "$soft" == "true" ]]; then preflight::warn "kubectl version $kubectl_ver != pinned $kubectl_pin (soft mode)"; else preflight::die "kubectl version $kubectl_ver != pinned $kubectl_pin"; fi
    fi
  fi

  # helm
  if command -v helm >/dev/null 2>&1; then
    local helm_ver; helm_ver=$(helm version --short --client 2>/dev/null | sed 's/+.*//' || true)
    if [[ "$helm_ver" != "$helm_pin" ]]; then
      if [[ "$soft" == "true" ]]; then preflight::warn "helm version $helm_ver != pinned $helm_pin (soft mode)"; else preflight::die "helm version $helm_ver != pinned $helm_pin"; fi
    fi
  fi

  # containerlab (parse the 'version: X.Y.Z' line from `containerlab version`)
  # containerlab >=0.7x prints an ASCII banner (possibly with ANSI color codes)
  # followed by "    version: X.Y.Z" with LEADING WHITESPACE. The parser must trim
  # the key and strip escape codes, otherwise a correct install reads as an empty
  # version and is reported as a mismatch.
  if command -v containerlab >/dev/null 2>&1; then
    local clab_ver esc
    esc=$(printf '\033')
    clab_ver=$(containerlab version 2>/dev/null | sed "s/${esc}\[[0-9;]*[a-zA-Z]//g" | awk -F': *' '{h=tolower($1); gsub(/[^a-z]/,"",h); if (h=="version") {v=$2; gsub(/[^0-9.]/,"",v); if (v!="") {print v; exit}}}')
    if [[ -z "$clab_ver" ]]; then
      # Fallback: first three-component version anywhere in the version output
      clab_ver=$(containerlab version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    fi
    if [[ -z "$clab_ver" ]]; then
      # Last resort: legacy flag form (older containerlab)
      clab_ver=$(containerlab --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    fi
    if [[ "$clab_ver" != "$clab_pin" ]]; then
      if [[ "$soft" == "true" ]]; then preflight::warn "containerlab version $clab_ver != pinned $clab_pin (soft mode)"; else preflight::die "containerlab version $clab_ver != pinned $clab_pin"; fi
    fi
  else
    if [[ "$soft" == "true" ]]; then preflight::warn "containerlab not installed (soft mode)"; else preflight::die "missing required command: containerlab"; fi
  fi
}

preflight::run() {
  preflight::check_versions_lock
  preflight::host_resources
  preflight::runtime_privileges
  preflight::address_conflicts
  preflight::mtu
  preflight::kvm_check
  preflight::tool_versions
  preflight::intent_tier_headroom
  echo "[preflight] basic host checks passed"
}

export -f preflight::run
