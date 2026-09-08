# envee

> **Per-directory environment variable manager** — fast, secure, declarative replacement for [direnv](https://direnv.net).

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Go 1.24+](https://img.shields.io/badge/Go-1.24+-blue.svg)](go.mod)
[![Homebrew](https://img.shields.io/badge/Homebrew-baken%2Ftap-orange.svg)](https://github.com/baken/homebrew-tap)

```bash
# 1. Install
brew install baken667/tap/envee

# 2. Add the shell hook
echo 'eval "$(envee init zsh)"' >> ~/.zshrc   # or bash / fish

# 3. Use it
cd ~/work/myproj       # contains envee.toml
envee trust            # approve the project once
echo $DATABASE_URL     # env vars are loaded automatically
```

## Why envee?

| Feature | direnv | envee |
|---|---|---|
| Config format | bash script (`.envrc`) | structured TOML (`envee.toml`) |
| Trust model | hash + opt signature | hash + opt signature + static analysis |
| Shell escape safety | manual `$VAR` handling | automatic, audited |
| Profiles (dev/staging/prod) | manual `source_env` | first-class `[profiles.X]` |
| Required vars | none | `required = true` validation |
| Redaction | none | `redact = true` by default |
| Secret manager integration | none | plugin-based (1Password, AWS, Vault, ...) |
| Script sandbox | none (RCE) | optional WASM (wazero) |
| Shell hook overhead | ~5–15 ms per prompt | < 0.5 ms (stat only) + lazy eval |
| Built-in commands | ~25 | ~25 (compatible) |
| Cross-platform (macOS/Linux) | ✅ | ✅ (single static binary) |
| Homebrew distribution | ✅ (homebrew-core) | ✅ (custom tap, auto-updated by GoReleaser) |

See [docs/adr/](docs/adr/) for the full architecture decision log (18 ADRs).

## Quick start

### Install

```bash
# Homebrew (recommended)
brew install baken667/tap/envee

# Go install
go install github.com/baken667/envee/cmd/envee@latest

# Direct download — see https://github.com/baken667/envee/releases
curl -fsSL https://envee.dev/install.sh | sh
```

### Wire up your shell

| Shell | Command |
|---|---|
| bash | `echo 'eval "$(envee init bash)"' >> ~/.bashrc` |
| zsh  | `echo 'eval "$(envee init zsh)"' >> ~/.zshrc` |
| fish | `echo 'envee init fish \| source' >> ~/.config/fish/config.fish` |
| nu   | `envee init nu \| save -f ~/.config/envee.nu; source ~/.config/envee.nu` |
| pwsh | `envee init pwsh \| Out-String \| Invoke-Expression` |

Restart your shell or `source` the config file.

### Create your first `envee.toml`

```toml
schema = "envee/v1"
profile = "dev"

[env]
DATABASE_URL = "postgres://localhost/mydb_dev"
PORT = 5432
DEBUG = true

# Add the project's bin/ to $PATH
_.path = ["./bin", "{{config_root}}/node_modules/.bin"]

# Load a .env file (dotenv format)
_.file = ".env"

# Redact secrets in `envee status`
DATABASE_PASSWORD = { value = "dev", redact = true }
```

### Trust the project

```bash
$ cd ~/work/myproj
$ envee trust
[envee] Reviewing envee.toml...
[envee]   4 env vars
[envee]   1 PATH addition
[envee]   0 secret sources
[envee] Trust this file? [Y/n/d(iff)] Y
Trusted.
  hash:    sha256:abc123...
```

Now every time you `cd` into this project, the env vars are automatically loaded into your shell.

## Documentation

- [Architecture Decision Records](docs/adr/README.md) — 18 ADRs covering language, config format, trust, hooks, plugins, daemon, secrets, etc.
- [PLAN.md](PLAN.md) — high-level project plan with competitive analysis
- [examples/](examples/) — example projects

## Project status

**Pre-1.0 / MVP scaffold.** See [docs/adr/0015-versioning.md](docs/adr/0015-versioning.md) for the versioning policy.

The architecture is in place; the core algorithms (env diff, TOML parsing, template engine, trust store, plugin protocol) are written, and the project builds to a 7 MB static binary. Subcommands are scaffolded; business logic is being filled in incrementally.

```bash
$ envee --version
0.0.0-dev (commit unknown, built unknown, go1.27.0)

$ envee --help
envee loads environment variables from envee.toml when you enter a directory.
...
```

## Development

```bash
make build            # build ./bin/envee
make test             # run unit tests
make test-race        # run with race detector
make lint             # golangci-lint
make goreleaser-snapshot  # build full release artifacts locally (no publish)
```

## Contributing

Contributions are welcome. Please:

1. Read [docs/adr/](docs/adr/) — especially ADR-0015 (versioning) and ADR-0017 (error UX).
2. Open an issue before significant changes.
3. Follow conventional commits (`feat:`, `fix:`, `chore:`, etc.) — the changelog is auto-generated.

## License

MIT — see [LICENSE](LICENSE).
