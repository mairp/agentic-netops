# T067 Topology ConfigMap generation proof

This repo includes a generator that produces the versioned topology ConfigMap directly from containerlab inspect JSON.

- Script: scripts/observability/gen-topology-configmap.sh
- Usage: containerlab inspect -t lab/topology.clab.yml -o json | scripts/observability/gen-topology-configmap.sh > deploy/observability/topology-configmap.yaml
- The script pulls node names/labels and link endpoints from the inspect output and serializes nodes/links and rate/util metrics into ConfigMap data.topology.json, with annotations:
  - ainetops.dev/source: containerlab
  - ainetops.dev/version: v1
  - ainetops.dev/schema: grafana-flow-topology

A proof-run should capture the input JSON and the generated YAML side-by-side along with their SHA256 hashes:

  containerlab inspect -t lab/topology.clab.yml -o json | tee .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/containerlab-inspect.json \
    | scripts/observability/gen-topology-configmap.sh | tee .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/topology-configmap.generated.yaml > /dev/null
  sha256sum .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/containerlab-inspect.json | nl -ba > .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/hash.containerlab-inspect.txt
  sha256sum .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/topology-configmap.generated.yaml | nl -ba > .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/hash.topology-configmap.generated.txt
