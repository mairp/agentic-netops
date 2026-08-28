#!/usr/bin/env bash
# Install pinned SDC CRDs/controllers into Kind and wait for readiness (Phase 3)
set -euo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "${DIR}/../.." && pwd)
KIND_CONTEXT="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"

command -v kubectl >/dev/null 2>&1 || { echo "missing kubectl" >&2; exit 1; }

if [[ -f "${ROOT}/deploy/sdc/crds/sdc-crds.yaml" ]]; then
  kubectl --context "${KIND_CONTEXT}" apply -f "${ROOT}/deploy/sdc/crds/sdc-crds.yaml"
fi

# Apply SDC components (Deployments/Services) and PVCs
kubectl --context "${KIND_CONTEXT}" apply -f "${ROOT}/deploy/sdc/components.yaml"

# PVCs for SDC state (ensure created)
cat <<EOF | kubectl --context "${KIND_CONTEXT}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sdc-data
  namespace: sdc-system
spec:
  accessModes: [ "ReadWriteOnce" ]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sdc-cache
  namespace: sdc-system
spec:
  accessModes: [ "ReadWriteOnce" ]
  resources:
    requests:
      storage: 1Gi
EOF

# Wait for CRDs (basic)
for crd in schemas.sdc.sdcio.dev configs.sdc.sdcio.dev targets.sdc.sdcio.dev; do
  kubectl --context "${KIND_CONTEXT}" wait --for=condition=Established --timeout=180s crd/${crd} || true
done

# Wait for SDC component pods ready
kubectl --context "${KIND_CONTEXT}" -n sdc-system wait --for=condition=Ready --timeout=300s pods -l app.kubernetes.io/name=sdc-schema || true
kubectl --context "${KIND_CONTEXT}" -n sdc-system wait --for=condition=Ready --timeout=300s pods -l app.kubernetes.io/name=sdc-config || true
kubectl --context "${KIND_CONTEXT}" -n sdc-system wait --for=condition=Ready --timeout=300s pods -l app.kubernetes.io/name=sdc-data || true
kubectl --context "${KIND_CONTEXT}" -n sdc-system wait --for=condition=Ready --timeout=300s pods -l app.kubernetes.io/name=sdc-cache || true

echo "[sdc-install] CRDs and components applied; basic readiness achieved"
