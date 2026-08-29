#!/usr/bin/env bash
# Generate a versioned topology ConfigMap from containerlab inspect output (JSON) and annotations
# Usage: containerlab inspect -t lab/topology.clab.yml -o json | scripts/observability/gen-topology-configmap.sh > deploy/observability/topology-configmap.yaml
set -euo pipefail

ANNOT_SOURCE=${ANNOT_SOURCE:-containerlab}
ANNOT_VERSION=${ANNOT_VERSION:-v1}
NAMESPACE=${NAMESPACE:-monitoring}
NAME=${NAME:-ainetops-topology}

jq -r --arg ns "$NAMESPACE" --arg name "$NAME" --arg source "$ANNOT_SOURCE" --arg ver "$ANNOT_VERSION" '
  def nodes: [.topology.nodes[] | {id: .name, role: (.labels.role // (if (.name | test("spine")) then "spine" else "leaf" end)), labels: {pod:"fabric", device:"sonic"}}];
  def links: [.topology.links[] | {source: .a.node, target: .b.node, if: (.a.interface // "" )}];
  {
    apiVersion:"v1", kind:"ConfigMap",
    metadata:{name:$name, namespace:$ns, labels:{"ainetops.dev/component":"topology"}, annotations:{"ainetops.dev/source":$source, "ainetops.dev/version":$ver, "ainetops.dev/schema":"grafana-flow-topology"}},
    data:{"topology.json": ( {nodes: nodes, links: links, metrics:{rate_metric:"sonic_interface_packets_total", util_metric:"sonic_interface_octets_total", labels:["device","interface","pod"]}} | tojson )}
  } | tojson' | jq -r '. | ("apiVersion: " + .apiVersion), ("kind: " + .kind), "metadata:", ("  name: " + .metadata.name), ("  namespace: " + .metadata.namespace), "  labels:", "    ainetops.dev/component: topology", "  annotations:", ("    ainetops.dev/source: " + .metadata.annotations["ainetops.dev/source"]), ("    ainetops.dev/version: " + .metadata.annotations["ainetops.dev/version"]), ("    ainetops.dev/schema: " + .metadata.annotations["ainetops.dev/schema"]), "data:", "  topology.json: |", ("    " + (.data["topology.json"] | gsub("\\n"; "\\n    ")))'
