# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Release notes on GitHub are generated from conventional commits; this file is
the curated view.

## [Unreleased]

### Security

- **Command injection in `envee eval` (all shells).** `ansiCEscape` emitted
  backslashes and single quotes unescaped inside `$'...'`, and `BashEscape`
  routed any value containing a control character *or a non-ASCII byte*
  through it. A value from a `.env` file or a secret plugin could therefore
  close the quoting and run arbitrary commands in the user's shell — the exact
  class of problem envee exists to avoid. `FishEscape` had the same hole for
  backslashes. Escaping is now round-tripped through real bash, zsh and fish in
  tests.
- **Trust was verified for only one config file.** A resolved config is merged
  from `envee.toml`, `envee.local.toml`, `envee.d/*.toml`, parent-directory
  configs and the global config, but only the first was checked. Anyone able
  to write `envee.d/*.toml` or `envee.local.toml` (gitignored, so unreviewed)
  had their env applied without approval. Every contributing file is now
  checked.
- **`envee exec`, `diff`, `resolve` and `status` had no trust check at all**,
  despite running directives that spawn secret plugins.
- **`ENVEE_BYPASS_TRUST=1` disabled the trust gate.** Since envee exports
  config values into the shell, one trusted config could set it and switch
  trust off for every other directory in the session. Removed; configs may no
  longer set any `ENVEE_*` variable.
- **`envee deny` did nothing.** The deny marker was written but never read, so
  a denied file could still be trusted and evaluated.

### Fixed

- Config discovery walked up two directory levels per iteration, so
  `envee.toml` in the immediate parent was never found — the monorepo layout
  in the README could not work.
- The global config path was built from a raw `$XDG_CONFIG_HOME`, yielding the
  relative path `envee` when unset (the norm on macOS):
  `~/.config/envee/config.toml` was never read, and any `./envee` directory was
  loaded in its place.
- `make build` produced binaries reporting `0.0.0-dev`: the ldflags named a
  module path that does not exist, and Go silently ignores `-X` for an unknown
  symbol.
- `envee status`: `--json`, `--show-secrets`, `--trust`, `--plugins` and
  `--daemon` were accepted and ignored; `--profile` was a local bool that
  shadowed the root command's persistent string flag.
- The daemon socket and lock file were written directly into the shared XDG
  runtime directory instead of a per-application subdirectory.
- Trust entries recorded `ToolVersion` as the literal `0.0.0-dev`.
- `DoubleQuoteEscape` inserted a spurious backslash before `!`; PowerShell
  `SetPath` leaked quote characters into `PATH`; every adapter emitted a
  leading empty `PATH` entry (which POSIX shells resolve as the current
  directory) when given no directories.

### Added

- `envee check` — real static analysis: missing `_.file`/`_.script`/`_.source`
  targets, secret plugins absent from `$PATH`, unredacted secrets, plaintext
  values whose names look like credentials, reserved `ENVEE_*` keys and
  circular template references. `--strict` and `--json`. It runs nothing and
  does not require trust, since checking is what you do before trusting.
- `envee doctor` — installation and configuration diagnostics, `--json`.
- `envee plugin list` / `plugin info` — plugin discovery and metadata.
- `envee daemon status` — probes the socket, distinguishing a running daemon
  from a stale socket file.
- `cmd/gen-docs` — generates shell completions and man pages, which release
  archives, Linux packages and the Homebrew formula now ship again.
- [docs/errors.md](docs/errors.md), [CONTRIBUTING.md](CONTRIBUTING.md),
  [SECURITY.md](SECURITY.md), issue and pull-request templates.

### Changed

- Commands that are not implemented are hidden from `--help` and return a
  non-zero error instead of printing a message and exiting 0. `envee telemetry
  enable` previously reported success for something that does not exist.
- The trust prompt lists secrets declared in the shorthand
  `NAME = { source = ..., ref = ... }` form. It previously showed
  `Secrets: 0` for such configs, never telling the user that approving them
  allows a plugin to be invoked.
- Release signing is keyless (Sigstore/Fulcio/Rekor) instead of a private key
  in repository secrets.
- Docker images are not built for now; the config referenced a Dockerfile that
  does not exist.
- `.golangci.yml` migrated to schema v2, so `golangci-lint` as installed by
  Homebrew can run it.
- Dependencies: cobra 1.8.1 → 1.10.2, BurntSushi/toml 1.5.0 → 1.6.0.

### Known issues

- The nushell and PowerShell hooks apply the environment in a child scope and
  do not affect the calling session. Both are marked experimental.
- `envee trust --sign` (ed25519) is not implemented.
- The WASM script sandbox (`_.script`) is not implemented.

[Unreleased]: https://github.com/baken667/envee/compare/v0.1.0...HEAD
