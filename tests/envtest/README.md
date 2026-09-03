Envtest suite

This directory contains Go tests that start a local Kubernetes API server and ETCD via controller-runtime's envtest, install our CRDs, and then validate server-side behavior using dry-run. It provides server-side dry-run/envtest coverage of the CRDs.

Run:

  go test ./tests/envtest -v

The test reads CRDs from config/crd/bases and samples from config/samples.

Notes:
- The test respects KUBEBUILDER_ASSETS if set.
- If not set, it attempts the common default /usr/local/kubebuilder/bin.
- If neither exists, tests will be skipped.
