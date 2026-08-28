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
  awk -v s="^"$section":$" -v k="^\\s*"$key":" 'f; $0~s{f=1} f && /^[^[:space:]]/{if(!p){p=1;print}else exit} f && p{if ($0~k){sub(/.*:[[:space:]]*/, ""); gsub(/\"/, ""); print; exit}}' "$file"
}

preflight::tool_versions() {
  # Verify host tool versions match pins in versions.lock.yaml
  for c in kind kubectl helm containerlab jq curl; do preflight::require_cmd "$c"; done

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
  local kind_ver; kind_ver=$(kind version 2>/dev/null | awk '{print $2}') || true
  [[ "$kind_ver" == "$kind_pin" ]] || preflight::die "kind version $kind_ver != pinned $kind_pin"

  # kubectl
  local kubectl_ver; kubectl_ver=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' || true)
  [[ "$kubectl_ver" == "$kubectl_pin" ]] || preflight::die "kubectl version $kubectl_ver != pinned $kubectl_pin"

  # helm
  local helm_ver; helm_ver=$(helm version --short --client 2>/dev/null | sed 's/+.*//' || true)
  [[ "$helm_ver" == "$helm_pin" ]] || preflight::die "helm version $helm_ver != pinned $helm_pin"

  # containerlab (parse the 'version:' line)
  local clab_ver; clab_ver=$(containerlab version 2>/dev/null | awk -F': *' '/^version:/ {print $2; exit}')
  [[ "$clab_ver" == "$clab_pin" ]] || preflight::die "containerlab version $clab_ver != pinned $clab_pin"
}

preflight::run() {
  preflight::check_versions_lock
  preflight::host_resources
  preflight::runtime_privileges
  preflight::address_conflicts
  preflight::mtu
  preflight::kvm_check
  preflight::tool_versions
  echo "[preflight] basic host checks passed"
}

export -f preflight::run
