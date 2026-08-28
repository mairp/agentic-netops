SHELL := /usr/bin/env bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: help verify-pins validate-crds verify-compat lab-qualify

help:
	@echo "Targets:"
	@echo "  verify-pins     Validate versions.lock.yaml has immutable pins and consistency"
	@echo "  validate-crds   Server-side dry-run validation of Kubenet/KUID/SDC CRDs and examples"
	@echo "  verify-compat   Run verify-pins and validate-crds together"
	@echo "  lab-qualify     Run lab capability qualification suite (blocks downstream on failure)"

verify-pins:
	@echo "[verify-pins] validating versions.lock.yaml"
	@"$(PWD)/scripts/lib/verify_pins.sh"

validate-crds:
	@echo "[validate-crds] server-side validating CRDs and examples"
	@mkdir -p .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs
	@"$(PWD)/scripts/lib/validate_crds.sh" 2>&1 | tee .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validate-crds.run.log

verify-compat: verify-pins validate-crds
	@echo "[verify-compat] pins and CRD validations passed"

lab-qualify:
	@echo "[lab-qualify] Running capability gate"
	@"$(PWD)/scripts/lib/qualify.sh"
