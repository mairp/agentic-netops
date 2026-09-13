#!/usr/bin/env bash
# Generate a versioned topology ConfigMap from containerlab inspect output (JSON) and annotations.
#
# Usage:
#   containerlab inspect -t lab/topology.clab.yml -o json \
#     | scripts/observability/gen-topology-configmap.sh > deploy/observability/topology-configmap.yaml
#
# The containerlab topology names fabric ports `e1-N`; the SR Linux node itself
# (and therefore the gNMI telemetry the collector labels series with) names them
# `ethernet-1/N`. The generator normalises to the device-side name so the
# topology ConfigMap joins against the `interface_name` label emitted by gnmic.
set -euo pipefail

ANNOT_SOURCE=${ANNOT_SOURCE:-containerlab}
ANNOT_VERSION=${ANNOT_VERSION:-v1}
NAMESPACE=${NAMESPACE:-monitoring}
NAME=${NAME:-agentic-netops-topology}

jq -r --arg ns "$NAMESPACE" --arg name "$NAME" --arg source "$ANNOT_SOURCE" --arg ver "$ANNOT_VERSION" '
  # e1-3 -> ethernet-1/3 ; anything already device-shaped is left alone.
  def srlif($i): ($i // "") | if test("^e[0-9]+-[0-9]+$") then sub("^e(?<s>[0-9]+)-(?<p>[0-9]+)$"; "ethernet-\(.s)/\(.p)") else . end;
  def nodes: [.topology.nodes[] | {id: .name, role: (.labels.role // (if (.name | test("spine")) then "spine" else "leaf" end)), labels: {pod:"fabric", device:"srlinux"}}];
  def links: [.topology.links[] | {source: .a.node, target: .b.node, if: srlif(.a.interface)}];
  {
    apiVersion:"v1", kind:"ConfigMap",
    metadata:{name:$name, namespace:$ns, labels:{"agentic-netops.dev/component":"topology"}, annotations:{"agentic-netops.dev/source":$source, "agentic-netops.dev/version":$ver, "agentic-netops.dev/schema":"grafana-flow-topology"}},
    data:{"topology.json": ( {nodes: nodes, links: links, metrics:{rate_metric:"interface_statistics_in_packets", util_metric:"interface_statistics_in_octets", labels:["source","interface_name","pod"]}} | tojson )}
  } | tojson' | jq -r '. | ("apiVersion: " + .apiVersion), ("kind: " + .kind), "metadata:", ("  name: " + .metadata.name), ("  namespace: " + .metadata.namespace), "  labels:", "    agentic-netops.dev/component: topology", "  annotations:", ("    agentic-netops.dev/source: " + .metadata.annotations["agentic-netops.dev/source"]), ("    agentic-netops.dev/version: " + .metadata.annotations["agentic-netops.dev/version"]), ("    agentic-netops.dev/schema: " + .metadata.annotations["agentic-netops.dev/schema"]), "data:", "  topology.json: |", ("    " + (.data["topology.json"] | gsub("\\n"; "\\n    ")))'
