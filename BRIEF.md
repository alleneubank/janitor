> Law doc for Janitor binary distribution, present-tense, no narrated history — git is the changelog. Amend Decisions and Boundary only with human confirmation; dated working memory lives outside this file.

## Bar

Janitor releases are shippable when every supported archive is secret-free,
hash-pinnable, executable through CLI package managers, and verified after its
actual archive round trip.

## Dimensions

- Artifact integrity and signature validity.
- Credential independence and reproducibility.
- Linux/macOS and x86_64/aarch64 coverage.
- Consumer fidelity: Nix installs the verified upstream bytes without building
  Janitor from source or relying on ambient PATH state.

## Floors

- `scripts/test-release-automation.sh` passes and rejects Developer ID,
  notarization, and Apple-secret dependencies in release automation.
- `sh -n scripts/release-macos.sh scripts/test-release-automation.sh` passes.
- A native macOS archive produced by `scripts/release-macos.sh` passes checksum
  verification and `codesign --verify --strict` after extraction.
- `zig build fmt`, `zig build test`, and `zig build check-plugin-version` pass.
- Fresh GitHub-hosted runners build all four target archives; downloaded macOS
  artifacts pass strict signature verification after extraction.
- The Janitor Nix overlay passes `nix flake check`, preserves upstream binary
  bytes, and runs `janitor --version` from the Nix store on a supported host.

## Oracle

Fresh GitHub-hosted release runners and clean Nix derivations are the objective
oracles. They reconstruct artifacts outside the maker's working tree and fail
closed on missing files, hash drift, invalid signatures, or build failures.

## Never

- Never require or access Apple identities, certificates, notarization
  credentials, signing passwords, or private keys.
- Never publish a macOS archive whose extracted binary fails strict signature
  verification.
- Never let the overlay compile Janitor from source or mutate upstream binary
  bytes during Nix fixup.
- Never require consumers to add Janitor to a global PATH.
- Never replace an existing release tag's artifacts in place.

## Decisions

- macOS CLI artifacts use credential-free ad-hoc signatures.
- The supported macOS distribution path is hash-verifying CLI/package-manager
  installation; quarantined browser/Finder downloads are outside the contract.
- Invalid published artifacts are superseded with a new patch release; existing
  tags and assets are never replaced in place.
- `alleneubank/janitor-overlay` is the reusable prebuilt-binary Nix source.
- Consumers invoke the overlay package by its absolute Nix store path; dev-shell
  PATH exposure is not the integration mechanism.
- Artifact integrity comes from immutable versioned URLs, committed SHA-256
  hashes, and flake locks.

## Boundary

- Publishing a tag, release, repository, or feature branch requires explicit
  user authorization naming that artifact.
- Merging into a deployment-tracked branch, deploying, and restarting a live
  localnet require separate human authorization.
- Any unexpected need for a secret, biometric approval, or destructive release
  replacement stops the loop.
