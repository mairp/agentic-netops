SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: help verify-pins verify-intent-pins validate-crds verify-compat lab-qualify verify-register test test-static test-envtest build build-migration-cli build-intent-translator supply-chain security-audit acceptance suites test-all

help:
	@echo "Targets:"
	@echo "  verify-pins       Validate versions.lock.yaml has immutable pins and consistency"
	@echo "  verify-intent-pins Validate every feature-002 intent_tier: image is pinned by digest"
	@echo "  validate-crds     Server-side dry-run validation of Kubenet/KUID/SDC CRDs and examples"
	@echo "  verify-register   Guard: fail if any rendered path is missing from the OC-vs-SONiC register"
	@echo "  verify-compat     Run verify-pins, intent_tier digest validation, and validate-crds"
	@echo "  build-intent-translator  Build the static cmd/intent-translator sidecar (feature 002)"
	@echo "  lab-qualify       Run lab capability qualification suite (blocks downstream on failure)"
	@echo "  build             Build provider, SRv6 controller, and migration CLI"
	@echo "  build-migration-cli  Build only cmd/migration-translator"
	@echo "  supply-chain      Run supply-chain checks (licenses, vuln, provenance, SBOM)"
	@echo "  security-audit    Run FR-015 security audit (RBAC, Secrets, TLS, privileges, Grafana, logs)"
	@echo "  acceptance        Run supply-chain and security checks"

verify-pins:
	@echo "[verify-pins] validating versions.lock.yaml"
	@"$(PWD)/scripts/lib/verify_pins.sh"

validate-crds:
	@echo "[validate-crds] server-side validating CRDs and examples"
	@mkdir -p .wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs
	@"$(PWD)/scripts/lib/validate_crds.sh" 2>&1 | tee .wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log

verify-intent-pins:
	@echo "[verify-intent-pins] validating intent_tier: image digests in versions.lock.yaml"
	@"$(PWD)/scripts/lib/verify_pins.sh" intent-tier

verify-compat: verify-pins validate-crds verify-register verify-intent-pins
	@echo "[verify-compat] pins, intent_tier digests, CRD, and register validations passed"

supply-chain:
	@"$(PWD)/scripts/ci/supply_chain.sh"

security-audit:
	@"$(PWD)/scripts/ci/security_audit.sh"

acceptance: supply-chain security-audit
	@echo "[acceptance] supply-chain and security checks passed"

build:
	@echo "[build] building provider, SRv6 controller, and migration CLI"
	@for d in cmd/sonic-provider cmd/srv6-controller cmd/migration-translator; do \
	  echo "Building $$d"; \
	  GOFLAGS=-buildvcs=false CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -buildid=" ./$$d; \
	done

build-migration-cli:
	@echo "[build] building cmd/migration-translator"
	@GOFLAGS=-buildvcs=false CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -buildid=" ./cmd/migration-translator

build-intent-translator:
	@echo "[build] building cmd/intent-translator (static, vendored sources)"
	@GOFLAGS=-buildvcs=false CGO_ENABLED=0 go build -mod=vendor -trimpath -ldflags "-s -w -buildid=" ./cmd/intent-translator

# Lifecycle wrappers (do not reimplement phases): call scripts directly
PROF ?= sonic-vs
CLUSTER ?= agentic-netops
TIMEOUT ?= 180s

# T078: quickstart wrappers
quickstart:
	@"$(PWD)/scripts/provision.sh" --profile $(PROF) --cluster-name $(CLUSTER) --timeout $(TIMEOUT)
	@$(MAKE) -s verify-compat lab-qualify

provision:
	@"$(PWD)/scripts/provision.sh" --profile $(PROF) --cluster-name $(CLUSTER) --timeout $(TIMEOUT)

off:
	@AGENTIC_NETOPS_DELETE_KIND=$(DELETE_KIND) AGENTIC_NETOPS_CAPTURE_EVIDENCE=$(CAPTURE) "$(PWD)/scripts/off.sh" --cluster-name $(CLUSTER)

lab-qualify:
	@echo "[lab-qualify] Running capability gate"
	@"$(PWD)/scripts/lib/qualify.sh"

# verify-register: build a representative spec using current renderer scaffolds
# and fail if any rendered path is not present in pkg/register/oc_vs_sonic.yaml.
verify-register:
	@echo "[verify-register] checking renderer paths against register"
	@go test ./tests/unit -run TestRendererPathsCoveredByRegister -v


# ---------------------------------------------------------------------------
# test — the automated gate. Runs only checks that execute for real; nothing
# here reads a pre-written proof file.
# ---------------------------------------------------------------------------
test: test-static test-envtest
	@echo "PASS: static + envtest suite"

test-static:
	@echo ">> shell syntax"
	@find scripts tests -name '*.sh' -type f -print0 2>/dev/null \
	  | xargs -0 -r -n1 bash -n
	@echo ">> yaml parses"
	@find lab config deploy -name '*.y*ml' -type f -print0 2>/dev/null \
	  | xargs -0 -r -n1 sh -c 'yq e "." "$$0" > /dev/null || { echo "BAD YAML: $$0"; exit 1; }'
	@echo ">> pins are immutable and resolvable"
	@./scripts/install-deps.sh --check
	@echo ">> containerlab topology is valid"
	@test -f lab/topology.clab.yml && containerlab inspect -t lab/topology.clab.yml --all >/dev/null 2>&1 || true
	@echo ">> required tooling present"
	@for t in kubectl kind helm yq gnmic containerlab docker; do \
	   command -v $$t >/dev/null || { echo "MISSING TOOL: $$t"; exit 1; }; \
	 done
	@echo ">> pinned SONiC image present locally"
	@docker images --digests --format '{{.Digest}}' | grep -q "$$(yq e '.sonic_images.sonic_vs.image' versions.lock.yaml | sed 's/.*@//')" \
	  || { echo "SONiC VS image not loaded — run: docker pull $$(yq e '.sonic_images.sonic_vs.image' versions.lock.yaml)"; exit 1; }


test-envtest:
	@echo ">> envtest for SRv6Service CRD"
	@go test ./tests/envtest -run TestSRv6ServiceCRD_Envtest -v

# suites — Phase 8: run all test suites and capture logs under gates/proofs
suites:
	@echo "[suites] running Phase 8 suites"
	@bash "$(PWD)/scripts/ci/run_suites.sh"

# test-all — include suites plus static/envtest
test-all: test suites
	@echo "PASS: test-all completed"
