# envee

> **Per-directory environment variable manager** — fast, secure, declarative replacement for [direnv](https://direnv.net).

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/Zig-0.16-f7a41d.svg)](build.zig.zon)
[![Homebrew](https://img.shields.io/badge/Homebrew-baken667%2Ftap-orange.svg)](https://github.com/baken667/homebrew-tap)

```bash
# 1. Install (Homebrew tap, or a prebuilt archive from the releases page)
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
| Shell hook overhead | ~5–15ms | ~5ms | **~0ms when nothing changed** (shell builtins only) |
| Cross-platform (macOS/Linux) | ✅ | ✅ | **✅ single static binary (~1 MB)** |
| Homebrew distribution | ✅ homebrew-core | ✅ homebrew-core | **✅ custom tap, prebuilt archives published on every tag** |

See [docs/adr/](docs/adr/) for the full architecture decision log (20 ADRs).

envee is written in [Zig](https://ziglang.org) with no dependencies beyond the
standard library. It started as a Go program; the rewrite and what changed
with it are in [ADR-0019](docs/adr/0019-language-zig.md).

## Quick start

### Install

```bash
# Homebrew (recommended)
brew install baken667/tap/envee

# Direct download: a prebuilt archive for linux/macOS (amd64, arm64) and
# windows (amd64), with checksums signed via Sigstore, from
# https://github.com/baken667/envee/releases
tar -xzf envee_*_linux_amd64.tar.gz && sudo install envee envee-plugin-env /usr/local/bin/

# From source (Zig 0.16)
zig build -Doptimize=ReleaseSafe && sudo install zig-out/bin/envee zig-out/bin/envee-plugin-env /usr/local/bin/
```

The archive contains `envee` and the bundled plugins (`envee-plugin-env`,
`envee-plugin-infisical`). All of them must be on `$PATH`.

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

Stored in `$XDG_DATA_HOME/envee/secrets/env.json`, which defaults to
`~/.local/share/envee/secrets/env.json` on every platform (mode 0600). This
is the one file that does not follow the macOS convention below, because the
plugin and `envee secret` must agree on it byte for byte.

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

Approvals live in the trust store: `~/.local/share/envee/trust/` on Linux and
`~/Library/Application Support/envee/trust/` on macOS (`$XDG_DATA_HOME`
overrides both). `envee doctor` prints the exact paths on your machine.

## Commands

| Command | Description |
|---|---|
| `envee init <shell>` | Output shell hook code |
| `envee trust [path]` | Approve an `envee.toml` (interactive) |
| `envee trust --sign` | Approve and sign the entry so it can be shared |
| `envee trust --from F --public-key K` | Import someone else's signed approval, after verifying it |
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
`envee debug`, `envee telemetry enable/disable` and `envee doctor --fix`.
They exit non-zero rather than pretending to succeed.

Error codes and exit codes are documented in [docs/errors.md](docs/errors.md).

## Sharing trust across a team

An approval can be signed, so one reviewer's decision can be reused instead of
every person re-reviewing the same config.

```bash
# Reviewer: approve and sign with an ed25519 SSH key.
envee trust --sign --key ~/.ssh/id_ed25519 --export envee.trust.json

# Everyone else: import it, verified against the reviewer's public key.
envee trust --from envee.trust.json --public-key reviewer.pub
```

The signature covers the config's content hash along with the rest of the
entry, so it stops being valid the moment the config changes — a re-review is
required rather than silently inherited. `--public-key` is mandatory on
import: accepting an entry without checking it would let anyone approve
configs on your behalf.

`envee status --trust` shows which entries are signed and by which key.

See [ADR-0004](docs/adr/0004-trust-model.md) for the design.

## Plugins

`envee` resolves secrets through a plugin protocol. A plugin is an executable
named `envee-plugin-<name>` in your `$PATH` that responds to `metadata` and
`resolve` subcommands over JSON-over-stdio.

Shipped:

| Plugin | Source |
|---|---|
| `envee-plugin-env` | Local key-value store (`envee secret set KEY=VAL`) |
| `envee-plugin-infisical` | [Infisical](https://infisical.com) through the `infisical` CLI (see below) |
| `envee-plugin-op` | (Phase 3) 1Password CLI |
| `envee-plugin-aws` | (Phase 3) AWS Secrets Manager / SSO |
| `envee-plugin-vault` | (Phase 3) HashiCorp Vault |
| `envee-plugin-sops` | (Phase 3) Mozilla SOPS |

### Infisical

`envee-plugin-infisical` ships with envee and delegates to the official
[`infisical` CLI](https://infisical.com/docs/cli/overview), so login, machine
identities, self-hosted instances and `.infisical.json` all work exactly as
they do for the CLI. Install it (`brew install infisical/get-cli/infisical`),
run `infisical login` (or set `INFISICAL_TOKEN` in CI), and `infisical init`
in the project once.

```toml
[env]
# ref = "[env:][/folder/]NAME"
DB_PASSWORD  = { source = "infisical", ref = "DB_PASSWORD", redact = true, required = true }
STRIPE_KEY   = { source = "infisical", ref = "prod:/payments/STRIPE_KEY", redact = true }
```

Which Infisical environment is used, in order: the `env:` prefix in the ref,
then `$INFISICAL_ENV`, then the active envee profile (`profile = "dev"` in
`envee.toml` selects Infisical's `dev`), then the CLI's default from
`.infisical.json`. `$INFISICAL_PROJECT_ID` selects the project explicitly; the
CLI runs in the directory of your `envee.toml`, where `.infisical.json`
normally lives. Failures carry the CLI's own message (`not_found`,
`unauthenticated`, `no_project`, `not_installed`, `timeout`).

Write your own plugin in 30 lines using [`pkg/sdk-go`](pkg/sdk-go/) — the Go
SDK is a separate module (`github.com/baken667/envee/pkg/sdk-go`) and works
unchanged with the Zig core. The wire protocol is in
[ADR-0007](docs/adr/0007-plugin-protocol.md); a plugin can be written in any
language that can read stdin and print JSON.

## Documentation

- [docs/errors.md](docs/errors.md) — every error code, what causes it, how to fix it
- [PLAN.md](PLAN.md) — high-level competitive analysis (Russian)
- [ROADMAP.md](ROADMAP.md) — A/B/C implementation plan (Russian)
- [docs/adr/](docs/adr/) — 20 Architecture Decision Records
- [docs/zig-rewrite.md](docs/zig-rewrite.md), [docs/zig-rewrite-steps.md](docs/zig-rewrite-steps.md) — how the Go → Zig rewrite was done, step by step, including the Go bugs it found (Russian)
- [examples/](examples/) — example projects

## Project status

**Pre-1.0.** The three planned milestones (eval, trust, plugins) are
implemented. 0.4.2 is the first release of the Zig implementation; upgrading
from 0.3.x requires one `envee trust` per project, because the content hash
is computed differently (see [ADR-0020](docs/adr/0020-canonical-hash-v2.md)).

Modules with tests (`zig build test`, ~360 tests):

```
  src/env.zig, dotenv.zig, template.zig, path.zig, paths.zig, errs.zig, log.zig
  src/toml/          (own TOML 1.0 parser, canonical form, hash)
  src/config.zig, resolver.zig, directive.zig, directive/file.zig
  src/shell/         (bash/zsh/fish/nu/pwsh adapters; hooks and escaping are
                      run through the real shells when they are installed)
  src/trust/         (store, summary, OpenSSH ed25519 keys, signatures —
                      cross-checked against entries signed by the Go version)
  src/plugin.zig, plugins/env.zig, secret_store.zig
  src/cli/           (every command, driven through the same code path as main)
  pkg/sdk-go         (plugin wire protocol, driven end to end as a subprocess)
```

Windows builds but is not tested; treat it as experimental.

## Development

Requires Zig 0.16.0 exactly (`build.zig.zon` pins it).

```bash
zig build                 # ./zig-out/bin/envee and ./zig-out/bin/envee-plugin-env
zig build test            # unit tests (add --summary all to see the count)
zig fmt --check src build.zig
zig build release         # cross-compile every release target into zig-out/release/
make examples             # static-check every example config
cd pkg/sdk-go && go test ./...   # the Go plugin SDK, if you touch it
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
