# Supply-chain checks

This project enforces the following for the fully open-source distribution:

- Enforced:
  - SR Linux absence in the dependency graph and runtime manifests.
  - All platform images in deploy/** are pinned by immutable digests.
- Advisory (documented, run when tools are available):
  - Vulnerability scanning via govulncheck
  - Dependency license reporting via go-licenses
  - SBOM generation via syft

Artifacts and commands:
- scripts/ci/supply_chain.sh — implements the checks and writes the proof artifacts
  - supply-chain.srlinux.ok.txt or supply-chain.srlinux.matches.txt
  - supply-chain.unpinned-images.txt (only when failures) or supply-chain.images-pinned.ok.txt
  - optional advisory outputs: supply-chain.govulncheck.txt, syft.sbom.json, supply-chain.licenses.txt
- Makefile target: make supply-chain

Presentation-only reference:
- README.md records the upstream telemetry visualization lab as a presentation-only pattern with no runtime dependency.
