# envee

> **Per-directory environment variable manager** — fast, secure, declarative replacement for [direnv](https://direnv.net).

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Go 1.24+](https://img.shields.io/badge/Go-1.24+-blue.svg)](go.mod)
[![Homebrew](https://img.shields.io/badge/Homebrew-baken667%2Ftap-orange.svg)](https://github.com/baken667/homebrew-tap)

```bash
# 1. Install (Homebrew, after first release)
brew install baken667/tap/envee

# 2. Add the shell hook
echo 'eval "$(envee init zsh)"' >> ~/.zshrc   # or bash / fish

# 3. Use it
cd ~/work/myproj       # contains envee.toml
envee trust            # approve the project once
echo $DATABASE_URL     # env vars are loaded automatically
```

## Why envee?

| Feature | direnv | mise | **envee** |
|---|---|---|---|
| Config format | bash (`.envrc`) | TOML | **TOML (`envee.toml`)** |
| Trust model | hash | hash | **hash + static analysis** (`envee check`; ed25519 signing is planned) |
| Profiles (dev/staging/prod) | manual `source_env` | `MISE_ENV=dev` | **first-class `[profiles.X]`** |
| Required vars | none | `required = true` | **`required = true` per profile** |
| Redaction | none | `redact = true` | **`redact = true` by default for secrets** |
| Secret plugins | none | none | **exec-based, 1Password/AWS/Vault/local** |
| Script sandbox | none (RCE) | none | **WASM (wazero) — planned, not implemented** |
| Shell hook overhead | ~5–15ms | ~5ms | **< 0.5ms (stat only) + lazy eval** |
| Cross-platform (macOS/Linux) | ✅ | ✅ | **✅ single static binary (5 MB)** |
| Homebrew distribution | ✅ homebrew-core | ✅ homebrew-core | **✅ custom tap, auto-publish via GoReleaser** |

See [docs/adr/](docs/adr/) for the full architecture decision log (18 ADRs).

## Quick start

### Install

```bash
# Homebrew (recommended, after first release)
brew install baken667/tap/envee

# Go install (any platform)
go install github.com/baken667/envee/cmd/envee@latest

# Direct download: grab a prebuilt archive (with a Sigstore signature)
# from https://github.com/baken667/envee/releases
```

### Wire up your shell

| Shell | Command |
|---|---|
| bash | `echo 'eval "$(envee init bash)"' >> ~/.bashrc` |
| zsh  | `echo 'eval "$(envee init zsh)"' >> ~/.zshrc` |
| fish | `echo 'envee init fish \| source' >> ~/.config/fish/config.fish` |
| nu   | *experimental* — `envee init nu \| save -f ~/.config/envee.nu; source ~/.config/envee.nu` |
| pwsh | *experimental* — `envee init pwsh \| Out-String \| Invoke-Expression` |

Restart your shell or `source` the config file.

> **nu and pwsh are not usable yet.** Both hooks apply the environment in a
> child scope — nushell runs `nu -c`, and the PowerShell hook is registered on
> `OnIdle`, which executes in a separate runspace — so nothing reaches your
> session. bash, zsh and fish work.

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

# Resolve a secret via a plugin (envee-plugin-env)
GITHUB_TOKEN = { source = "env", ref = "GITHUB_TOKEN", redact = true }
```

### Manage local secrets

```bash
$ envee secret set DATABASE_PASSWORD=hunter2
$ envee secret set GITHUB_TOKEN=ghp_xxxxxxxxxxxx
$ envee secret list
DATABASE_PASSWORD=***REDACTED***
GITHUB_TOKEN=***REDACTED***
```

Stored in `~/.local/share/envee/secrets/env.json` (mode 0600).

### Trust the project

```bash
$ cd ~/work/myproj
$ envee trust
[envee] Trust envee.toml at /Users/alice/work/myproj
  Schema:     envee/v1
  Profile:    dev
  Hash:       sha256:abc123...

  Env vars:   5 (2 marked redact)
  PATH adds:  2
  Files:      1

Trust this file? [Y/n/d(iff)/s(kip)/q(uit)] y
Trusted.
  hash:    sha256:abc123...
  expires: never
```

Now every time you `cd` into this project, the env vars are automatically loaded into your shell.

## Commands

| Command | Description |
|---|---|
| `envee init <shell>` | Output shell hook code |
| `envee trust [path]` | Approve an `envee.toml` (interactive) |
| `envee deny [path]` | Block an `envee.toml` |
| `envee status` | Show current state and resolved env |
| `envee resolve` | Compute and print the resolved environment (text or JSON) |
| `envee eval <shell>` | Print shell-specific export/unset commands (used by hook) |
| `envee diff <shell>` | Preview env changes without applying |
| `envee exec -- <cmd>` | Run a command with the loaded env |
| `envee check` | Static analysis of `envee.toml` |
| `envee secret set/unset/list/get` | Manage the local `envee-plugin-env` store |
| `envee doctor` | Health diagnostics |
| `envee plugin list/info` | Inspect discovered plugins |
| `envee daemon status` | Check whether the optional `enveed` daemon is running |
| `envee version` | Show envee version |

Planned, and currently hidden from `--help` because they are not implemented:
`envee plugin install`, `envee daemon start/stop`, `envee upgrade`,
`envee debug`, `envee telemetry enable/disable`, `envee doctor --fix` and
`envee trust --sign`. They exit non-zero rather than pretending to succeed.

Error codes and exit codes are documented in [docs/errors.md](docs/errors.md).

## Plugins

`envee` resolves secrets through a plugin protocol. A plugin is an executable
named `envee-plugin-<name>` in your `$PATH` that responds to `metadata` and
`resolve` subcommands over JSON-over-stdio.

Shipped:

| Plugin | Source |
|---|---|
| `envee-plugin-env` | Local key-value store (`envee secret set KEY=VAL`) |
| `envee-plugin-op` | (Phase 3) 1Password CLI |
| `envee-plugin-aws` | (Phase 3) AWS Secrets Manager / SSO |
| `envee-plugin-vault` | (Phase 3) HashiCorp Vault |
| `envee-plugin-sops` | (Phase 3) Mozilla SOPS |

Write your own plugin in 30 lines using [`pkg/sdk-go`](pkg/sdk-go/).

## Documentation

- [docs/errors.md](docs/errors.md) — every error code, what causes it, how to fix it
- [PLAN.md](PLAN.md) — high-level competitive analysis (Russian)
- [ROADMAP.md](ROADMAP.md) — A/B/C implementation plan (Russian)
- [docs/adr/](docs/adr/) — 18 Architecture Decision Records
- [examples/](examples/) — example projects

## Project status

**Pre-1.0.** The three planned milestones (eval, trust, plugins) are
implemented. There is no published release yet.

Packages with tests:

```
  internal/cli         (check, eval golden tests)
  internal/config      (TOML parser, profile flattening)
  internal/directive   (Apply orchestrator: file, path, profile, secret, template)
  internal/dotenv      (.env parser, hand-written state machine)
  internal/env         (Map type, diff, merge)
  internal/log         (redaction of sensitive attributes)
  internal/paths       (XDG path invariants)
  internal/plugin      (subprocess protocol: timeouts, bad exits, malformed
                        output, dispatch)
  internal/resolver    (discovery, merge, trust source tracking)
  internal/shell       (bash/zsh/fish/nu/pwsh adapters; escaping is round-tripped
                        through real bash, zsh and fish)
  internal/template    (Jinja-lite, cycle detection)
  internal/trust       (XDG_DATA_HOME store, summary)
  pkg/sdk-go           (plugin wire protocol, driven end to end as a subprocess)
```

Not yet covered: `internal/daemon` and `internal/errs`.

## Development

```bash
make build            # build ./bin/envee (and ./bin/enveed)
make test             # run unit tests
make test-race        # run with race detector
make lint             # golangci-lint
make goreleaser-snapshot  # build full release artifacts locally (no publish)
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
