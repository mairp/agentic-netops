This controller binary reuses the same pinned Go module set as the provider.

- Single go.mod at repo root pins controller-runtime, k8s.io/*, OTel, Prometheus, zap.
- Both cmd/sonic-provider and cmd/srv6-controller build against go.mod and go.sum.
- Proof slices: see .wiggum/.../gates/proofs/go.mod.proof.txt.
