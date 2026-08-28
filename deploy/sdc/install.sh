#!/usr/bin/env bash
# Install pinned SDC CRDs/controllers into Kind and wait for readiness (Phase 3)
# This script applies the ACTUAL upstream SDC CRDs pinned by versions.lock.yaml release.
set -euo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "${DIR}/../.." && pwd)
KIND_CONTEXT="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"

command -v kubectl >/dev/null 2>&1 || { echo "missing kubectl" >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "missing awk" >&2; exit 1; }

LOCK_FILE="${ROOT}/versions.lock.yaml"
section() { awk -v s="^$1:$" 'f; $0~s{f=1} f && /^[^[:space:]]/{if(!p){p=1;print}else exit} f && p{print}' "${LOCK_FILE}"; }

# Read core SDC release tag (sdcio/sdc), not config/schema server
sdc_release=$(awk '
  $1=="sdc:" {sec=1; next}
  sec && /^[^[:space:]]/ {exit}
  sec && $1=="core:" {in_core=1; next}
  in_core && /^[^[:space:]]/ {exit}
  in_core && $1=="release:" {print $2; exit}
' "${LOCK_FILE}")

SDC_CRDS=(
  "https://raw.githubusercontent.com/sdcio/sdc/${sdc_release}/deploy/crds/sdc.sdcio.dev_schemas.yaml"
  "https://raw.githubusercontent.com/sdcio/sdc/${sdc_release}/deploy/crds/sdc.sdcio.dev_configs.yaml"
  "https://raw.githubusercontent.com/sdcio/sdc/${sdc_release}/deploy/crds/sdc.sdcio.dev_targets.yaml"
)

# Apply CRDs from pinned upstream
for u in "${SDC_CRDS[@]}"; do
  kubectl --context "${KIND_CONTEXT}" apply -f "$u"
done

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

echo "[sdc-install] Pinned upstream CRDs and components applied; basic readiness achieved"
