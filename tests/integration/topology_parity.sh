#!/usr/bin/env bash
# T079: Topology parity test — verify that the generated/pinned topology ConfigMap
# (deploy/observability/topology-configmap.yaml) matches the containerlab topology
# (lab/topology.clab.yml) by node ids and undirected link endpoints.
#
# The test prefers live containerlab inspect JSON on stdin or via --inspect <path.json>.
# When inspect JSON is not available, it derives expected nodes/links from the
# containerlab topology YAML directly (best-effort static check suitable for CI).
#
# Outputs a human-readable report to stdout and exits non-zero on mismatch.
# Emits the symbol TOPOLOGY_PARITY_OK on success for gate proof grepping.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOPO_YAML=${TOPO_YAML:-"${ROOT_DIR}/lab/topology.clab.yml"}
CONFIGMAP_YAML=${CONFIGMAP_YAML:-"${ROOT_DIR}/deploy/observability/topology-configmap.yaml"}
INSPECT_JSON=${INSPECT_JSON:-}

usage(){
  cat <<EOF
Usage: $0 [--inspect path.json]
  --inspect path.json  Optional containerlab inspect JSON file to prefer
Environment overrides:
  TOPO_YAML, CONFIGMAP_YAML, INSPECT_JSON
EOF
}

while [[ $# > 0 ]]; do
  case "$1" in
    --inspect) shift; INSPECT_JSON=${1:-$INSPECT_JSON};;
    -h|--help) usage; exit 0 ;;
    *) echo "[topology-parity] unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift || true
done

# read_nodes_links_from_topology: outputs two lines: "NODES: a b c" and "LINKS: a-b c-d ..."
read_nodes_links_from_topology(){
  local yaml=$1
  # Nodes: capture lines inside "nodes:" mapping that look like "  name:" (spine01:, leaf01:, etc.)
  # Accept alnum/underscore/hyphen. Trim trailing colon.
  local nodes
  nodes=$(awk '
    $0 ~ /^[[:space:]]*nodes:[[:space:]]*$/ { in_nodes=1; next }
    in_nodes && $0 ~ /^[[:space:]]*links:[[:space:]]*$/ { in_nodes=0 }
    in_nodes && $0 ~ /^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*$/ { gsub(":",""); gsub(/^[[:space:]]+/,""); print $0 }
  ' "$yaml" | tr '\n' ' ')
  # Links: find "- endpoints: [a:x, b:y]" -> produce sorted endpoint pair "a-b"
  # Use POSIX awk and character classes; extract text between [ and ] via sub()
  local links
  links=$(awk '
    {
      if ($0 ~ /-[[:space:]]*endpoints:[[:space:]]*\[/) {
        s=$0
        sub(/^.*\[/, "", s)
        sub(/\].*$/, "", s)
        # split on comma into two endpoint specs
        n=split(s, parts, ",")
        if (n>=2) {
          p1=parts[1]; p2=parts[2]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", p1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", p2)
          split(p1, a, ":"); split(p2, b, ":")
          n1=a[1]; n2=b[1]
          if (n1 ~ /^(spine|leaf)[0-9]+$/ && n2 ~ /^(spine|leaf)[0-9]+$/) {
            if (n1 < n2) { print n1 "-" n2 } else { print n2 "-" n1 }
          }
        }
      }
    }
  ' "$yaml" | sort -u | tr '\n' ' ')
  # For nodes, restrict to those participating in fabric links (spine/leaf)
  local nodes_from_links
  nodes_from_links=$(tr ' ' '\n' <<<"$links" | awk -F- '{print $1"\n"$2}' | sort -u | tr '\n' ' ')
  # Fallback when no fabric links parsed: use node list filtered to spine/leaf
  if [[ -z "$nodes_from_links" ]]; then
    nodes_from_links=$(tr ' ' '\n' <<<"$nodes" | grep -E '^(spine|leaf)[0-9]+$' | sort -u | tr '\n' ' ')
  fi
  echo "NODES: $nodes_from_links"
  echo "LINKS: $links"
}

# read_nodes_links_from_configmap: parse topology.json from the pinned ConfigMap YAML
read_nodes_links_from_configmap(){
  local cm=$1
  # Extract the embedded JSON block and parse with jq if available; else use grep/sed.
  local json
  json=$(awk '/^[[:space:]]*topology.json: \|/{flag=1; next} /^\S/{flag=0} flag{print substr($0,5)}' "$cm" | tr -d '\r')
  if command -v jq >/dev/null 2>&1; then
    local nodes links
    nodes=$(jq -r '.nodes[].id' <<<"$json" | sort -u | tr '\n' ' ')
    links=$(jq -r '.links[] | [.source, .target] | sort | join("-")' <<<"$json" | sort -u | tr '\n' ' ')
    echo "NODES: $nodes"
    echo "LINKS: $links"
  else
    # Fallback regex parsing for ids and links
    local nodes links
    nodes=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]\+"' <<<"$json" | sed -E 's/.*:[[:space:]]*"([^"]+)"/\1/' | sort -u | tr '\n' ' ')
    links=$(grep -E '"source"|"target"' <<<"$json" | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/' | paste - - \
      | awk '{ a=$1; b=$2; if (a<b) {print a"-"b} else {print b"-"a} }' | sort -u | tr '\n' ' ')
    echo "NODES: $nodes"
    echo "LINKS: $links"
  fi
}

# Helper to safely populate an array with two lines (NODES:/LINKS:) even when parsing fails
_safe_read_topology_into_array(){
  local -n _out=$1
  local yaml=$2
  local t1 t2
  t1="NODES: "; t2="LINKS: "
  local tmp_out
  tmp_out=$(read_nodes_links_from_topology "$yaml" 2>/dev/null || true)
  if [[ -n "$tmp_out" ]]; then
    t1=$(printf "%s\n" "$tmp_out" | sed -n '1p')
    t2=$(printf "%s\n" "$tmp_out" | sed -n '2p')
  fi
  _out=("$t1" "$t2")
}

# If inspect JSON provided, prefer it to derive expected nodes/links
if [[ -n "${INSPECT_JSON:-}" && -f "$INSPECT_JSON" ]]; then
  echo "[topology-parity] INFO: using inspect JSON: $INSPECT_JSON" >&2
  # Expect JSON structure: .topology.nodes[].name and .topology.links[].a.node/.b.node
  if command -v jq >/dev/null 2>&1; then
    exp_nodes=$(jq -r '.topology.nodes[].name' "$INSPECT_JSON" | sort -u | tr '\n' ' ')
    exp_links=$(jq -r '.topology.links[] | [.a.node, .b.node] | sort | join("-")' "$INSPECT_JSON" | sort -u | tr '\n' ' ')
    echo "EXPECTED NODES: $exp_nodes"
    echo "EXPECTED LINKS: $exp_links"
  else
    echo "[topology-parity] WARN: jq not available; falling back to YAML parsing" >&2
    arr=("NODES: " "LINKS: ")
    _safe_read_topology_into_array arr "$TOPO_YAML"
    exp_nodes=${arr[0]#NODES: } ; exp_links=${arr[1]#LINKS: }
  fi
else
  arr=("NODES: " "LINKS: ")
  _safe_read_topology_into_array arr "$TOPO_YAML"
  exp_nodes=${arr[0]#NODES: } ; exp_links=${arr[1]#LINKS: }
  echo "EXPECTED NODES: $exp_nodes"
  echo "EXPECTED LINKS: $exp_links"
fi

mapfile -t cmarr < <(read_nodes_links_from_configmap "$CONFIGMAP_YAML")
cm_nodes=${cmarr[0]#NODES: } ; cm_links=${cmarr[1]#LINKS: }

declare -A expn cmn
mismatch=0
for n in $exp_nodes; do expn[$n]=1; done
for n in $cm_nodes; do cmn[$n]=1; done

# Compare node sets
for n in "${!expn[@]}"; do if [[ -z "${cmn[$n]:-}" ]]; then echo "MISSING NODE in ConfigMap: $n"; mismatch=1; fi; done
for n in "${!cmn[@]}"; do if [[ -z "${expn[$n]:-}" ]]; then echo "EXTRA NODE in ConfigMap: $n"; mismatch=1; fi; done

# Compare link sets
declare -A expl cml
for e in $exp_links; do expl[$e]=1; done
for e in $cm_links; do cml[$e]=1; done
for e in "${!expl[@]}"; do if [[ -z "${cml[$e]:-}" ]]; then echo "MISSING LINK in ConfigMap: $e"; mismatch=1; fi; done
for e in "${!cml[@]}"; do if [[ -z "${expl[$e]:-}" ]]; then echo "EXTRA LINK in ConfigMap: $e"; mismatch=1; fi; done

exp_node_count=$(wc -w <<<"$exp_nodes" | tr -d ' ')
cm_node_count=$(wc -w <<<"$cm_nodes" | tr -d ' ')
exp_link_count=$(wc -w <<<"$exp_links" | tr -d ' ')
cm_link_count=$(wc -w <<<"$cm_links" | tr -d ' ')

echo "COUNTS: expected nodes=$exp_node_count, configmap nodes=$cm_node_count; expected links=$exp_link_count, configmap links=$cm_link_count"

if [[ $mismatch -eq 0 ]]; then
  echo "TOPOLOGY_PARITY_OK: nodes and links match between lab/topology.clab.yml and deploy/observability/topology-configmap.yaml"
else
  echo "TOPOLOGY_PARITY_FAIL: mismatch detected" >&2
  exit 1
fi
