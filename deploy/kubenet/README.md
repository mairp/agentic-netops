This directory holds pinned manifests (or Helm values) for Kubenet and KUID CRDs/controllers to be installed inside Kind.

Per contract:
- All Kubernetes resources are installed inside Kind.
- Versions are pinned by commit/release in versions.lock.yaml.
- Installation occurs via scripts/provision.sh after the Kind cluster is ready.
