# Supply-chain checks

This project enforces the following for the fully open-source distribution:

- Enforced:
  - **SONiC absence** in the dependency graph and runtime manifests. The fabric
    is Nokia SR Linux (`ghcr.io/nokia/srlinux`, pinned by immutable digest in
    `versions.lock.yaml`), and no SONiC artifact may appear in `go.mod`,
    `go.sum`, `cmd/`, `config/`, `deploy/` or `lab/`. The deny pattern is
    `\bsonic\b|sonic-vs|sonic-net|sonic_yang`.
    This policy is the inverse of the one the previous generation enforced; the
    migration record and the SONiC-era findings are kept under `docs/legacy/`,
    which is deliberately outside the scanned set.
  - All platform images in `deploy/**` are pinned by immutable digests.
  - `scripts/lib/verify_pins.sh` (`make verify-pins`) additionally refuses any
    `sonic` key in `versions.lock.yaml` and requires the SR Linux image to come
    from the public `ghcr.io/nokia/srlinux` repository with a matching
    `srlinux_yang` compatibility entry.
- Advisory (documented, run when tools are available):
  - Vulnerability scanning via govulncheck
  - Dependency license reporting via go-licenses
  - SBOM generation via syft

Artifacts and commands:
- `scripts/ci/supply_chain.sh` — implements the checks and writes the proof artifacts
  - `supply-chain.sonic.ok.txt` or `supply-chain.sonic.matches.txt`
  - `supply-chain.unpinned-images.txt` (only when failures) or `supply-chain.images-pinned.ok.txt`
  - optional advisory outputs: `supply-chain.govulncheck.txt`, `syft.sbom.json`, `supply-chain.licenses.txt`
- Makefile target: `make supply-chain`

Proof artifacts are written under
`.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs/`.

Presentation-only reference:
- README.md records the upstream telemetry visualization lab as a
  presentation-only pattern with no runtime dependency.
