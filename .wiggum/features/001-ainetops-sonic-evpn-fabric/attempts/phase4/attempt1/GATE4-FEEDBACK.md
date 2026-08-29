# Phase 4 deterministic verification gate rejected

The fixed-argv verification gate failed (exit 10). The failing command
below is the ONLY thing that can clear this gate. Fix the CODE it points
at. Re-writing .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/GATE4-EVIDENCE.md, regenerating proofs, or
restating that the work is done will NOT change this result.

## What actually failed

### CMD-7b0518e1174ca872060e — exit 1

`/usr/lib/go-1.24/bin/go test ./...`  (cwd: /root/ainetops-demo)

stdout (last 80 lines):

```
FAIL	github.com/mairp/ainetops/api/v1alpha1 [setup failed]
FAIL	github.com/mairp/ainetops/cmd/sonic-provider [setup failed]
FAIL	github.com/mairp/ainetops/cmd/srv6-controller [setup failed]
FAIL	github.com/mairp/ainetops/controllers/sonicprovider [setup failed]
FAIL	github.com/mairp/ainetops/controllers/srv6service [setup failed]
ok  	github.com/mairp/ainetops/internal/lockfile	(cached)
?   	github.com/mairp/ainetops/pkg/compat	[no test files]
?   	github.com/mairp/ainetops/pkg/model	[no test files]
?   	github.com/mairp/ainetops/pkg/version	[no test files]
FAIL
```

stderr (last 40 lines):

```
	go get github.com/mairp/ainetops/cmd/sonic-provider
# github.com/mairp/ainetops/cmd/srv6-controller
cmd/sonic-provider/main.go:23:2: missing go.sum entry for module providing package sigs.k8s.io/controller-runtime/pkg/manager (imported by github.com/mairp/ainetops/cmd/sonic-provider); to add:
	go get github.com/mairp/ainetops/cmd/sonic-provider
# github.com/mairp/ainetops/controllers/sonicprovider
cmd/sonic-provider/main.go:13:2: github.com/prometheus/client_golang@v1.19.0: missing go.sum entry for go.mod file; to add it:
	go mod download github.com/prometheus/client_golang
# github.com/mairp/ainetops/controllers/sonicprovider
controllers/sonicprovider/controller.go:8:2: missing go.sum entry for module providing package k8s.io/api/core/v1 (imported by github.com/mairp/ainetops/cmd/sonic-provider); to add:
	go get github.com/mairp/ainetops/cmd/sonic-provider
# github.com/mairp/ainetops/controllers/sonicprovider
api/v1alpha1/groupversion_info.go:8:2: missing go.sum entry for module providing package k8s.io/apimachinery/pkg/runtime (imported by github.com/mairp/ainetops/api/v1alpha1); to add:
	go get github.com/mairp/ainetops/api/v1alpha1
# github.com/mairp/ainetops/controllers/sonicprovider
controllers/sonicprovider/controller.go:10:2: missing go.sum entry for module providing package sigs.k8s.io/controller-runtime (imported by github.com/mairp/ainetops/cmd/sonic-provider); to add:
	go get github.com/mairp/ainetops/cmd/sonic-provider
# github.com/mairp/ainetops/controllers/sonicprovider
controllers/sonicprovider/controller.go:11:2: missing go.sum entry for module providing package sigs.k8s.io/controller-runtime/pkg/client (imported by github.com/mairp/ainetops/controllers/sonicprovider); to add:
	go get github.com/mairp/ainetops/controllers/sonicprovider
# github.com/mairp/ainetops/controllers/sonicprovider
controllers/sonicprovider/controller.go:12:2: missing go.sum entry for module providing package sigs.k8s.io/controller-runtime/pkg/predicate (imported by github.com/mairp/ainetops/controllers/sonicprovider); to add:
	go get github.com/mairp/ainetops/controllers/sonicprovider
# github.com/mairp/ainetops/controllers/srv6service
cmd/sonic-provider/main.go:13:2: github.com/prometheus/client_golang@v1.19.0: missing go.sum entry for go.mod file; to add it:
	go mod download github.com/prometheus/client_golang
# github.com/mairp/ainetops/controllers/srv6service
api/v1alpha1/srv6service_types.go:6:2: missing go.sum entry for module providing package k8s.io/apimachinery/pkg/apis/meta/v1 (imported by github.com/mairp/ainetops/api/v1alpha1); to add:
	go get github.com/mairp/ainetops/api/v1alpha1
# github.com/mairp/ainetops/controllers/srv6service
api/v1alpha1/groupversion_info.go:8:2: missing go.sum entry for module providing package k8s.io/apimachinery/pkg/runtime (imported by github.com/mairp/ainetops/api/v1alpha1); to add:
	go get github.com/mairp/ainetops/api/v1alpha1
# github.com/mairp/ainetops/controllers/srv6service
api/v1alpha1/groupversion_info.go:7:2: missing go.sum entry for module providing package k8s.io/apimachinery/pkg/runtime/schema (imported by github.com/mairp/ainetops/api/v1alpha1); to add:
	go get github.com/mairp/ainetops/api/v1alpha1
# github.com/mairp/ainetops/controllers/srv6service
controllers/sonicprovider/controller.go:10:2: missing go.sum entry for module providing package sigs.k8s.io/controller-runtime (imported by github.com/mairp/ainetops/cmd/sonic-provider); to add:
	go get github.com/mairp/ainetops/cmd/sonic-provider
# github.com/mairp/ainetops/controllers/srv6service
controllers/sonicprovider/controller.go:11:2: missing go.sum entry for module providing package sigs.k8s.io/controller-runtime/pkg/client (imported by github.com/mairp/ainetops/controllers/sonicprovider); to add:
	go get github.com/mairp/ainetops/controllers/sonicprovider
```


## References

- Canonical verification plan: `/root/ainetops-demo/.wiggum/features/001-ainetops-sonic-evpn-fabric/runs/20260829-000424-1241911/verification/verification-plan.json`
- Verification evidence: `/root/ainetops-demo/.wiggum/features/001-ainetops-sonic-evpn-fabric/runs/20260829-000424-1241911/verification/phase-4-attempt-1.json`

The phase cannot be approved solely from the proposer or critic claim.
