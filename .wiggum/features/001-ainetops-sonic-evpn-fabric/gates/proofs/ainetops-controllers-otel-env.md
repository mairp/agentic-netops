# T064 proof: AINETOPS controllers OTLP export settings

Anchored manifests show OTEL_EXPORTER_OTLP_ENDPOINT pointing to the in-cluster OTel Collector Service.

- deploy/ainetops/manifests/provider.yaml lines 32-36 include:
  OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector.ainetops-system:4318

- deploy/ainetops/manifests/srv6-controller.yaml lines 28-32 include:
  OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector.ainetops-system:4318

At runtime, verify with:

  kubectl --context kind-ainetops -n ainetops-system get pods -l app.kubernetes.io/name=ainetops-sonic-provider -o jsonpath='{.items[0].spec.containers[0].env}' | jq | nl -ba > .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-env-ainetops-sonic-provider.txt
  kubectl --context kind-ainetops -n ainetops-system get pods -l app.kubernetes.io/name=ainetops-srv6-controller -o jsonpath='{.items[0].spec.containers[0].env}' | jq | nl -ba > .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-env-ainetops-srv6-controller.txt
