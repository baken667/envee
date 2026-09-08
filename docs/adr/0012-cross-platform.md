# ADR-012: Cross-platform strategy — macOS/Linux first-class, Windows experimental

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: На каких ОС работает envee, с какими ограничениями

## Контекст

Target audience:
- **macOS** (primary, ~70% user'ов direnv — Apple dev crowd).
- **Linux** (primary, ~25% — x86_64, aarch64, иногда musl для alpine/docker).
- **Windows** (tertiary, ~5% — WSL2, Git Bash, native экспериментально).

Direnv officially supports Windows начиная с v2.30+, но на практике — WSL или Git Bash. Нативный Windows — pain.

## Решение

### Tier 1: First-class (MVP)

| OS | Arch | Distribution |
|---|---|---|
| macOS | amd64 (Intel) | Homebrew, manual, `go install` |
| macOS | arm64 (Apple Silicon) | Homebrew, manual, `go install` |
| Linux | amd64 (glibc) | Homebrew on Linux, deb, rpm, manual, `go install` |
| Linux | arm64 (glibc) | Homebrew on Linux, deb, rpm, manual, `go install` |

### Tier 2: Best-effort (MVP)

| OS | Arch | Distribution | Notes |
|---|---|---|---|
| Linux | amd64 (musl) | Static tarball, `go install` | Alpine Docker, distroless |
| Linux | armv7 (glibc) | Static tarball, deb, rpm | Raspberry Pi |
| FreeBSD | amd64 | Manual, ports | Community-maintained |

### Tier 3: Experimental (Phase 3)

| OS | Arch | Distribution | Notes |
|---|---|---|---|
| Windows | amd64 | scoop, manual, `go install` | PowerShell + Git Bash hooks |
| Windows | arm64 | manual, `go install` | Surface Pro X |

## Платформо-зависимые куски

### Filesystem paths

**Rule**: внутренне используем `filepath` (Go stdlib, OS-aware). В конфигах — forward slashes (TOML convention, кросс-платформенный). При выводе в shell — forward slashes (bash на Windows через Git Bash понимает).

### Shell hooks

| Shell | macOS | Linux | Windows |
|---|---|---|---|
| bash | ✅ | ✅ | ⚠️ (Git Bash / WSL) |
| zsh | ✅ (default shell) | ✅ | ❌ |
| fish | ✅ | ✅ | ⚠️ (через WSL) |
| nu | ✅ | ✅ | ✅ (MVP: лучше, чем у direnv) |
| pwsh | ⚠️ | ⚠️ | ✅ (native) |
| elvish | ✅ | ✅ | ❌ |

**В MVP**: bash, zsh, fish на Tier 1. **Phase 2**: nu. **Phase 3**: pwsh, elvish.

### Daemon IPC

| OS | Mechanism | Library |
|---|---|---|
| macOS | UNIX socket (`$XDG_RUNTIME_DIR/envee.sock`) | `net.UnixListener` |
| Linux | UNIX socket (abstract namespace предпочтительно) | `net.UnixListener` |
| Windows | Named pipe (`\\.\pipe\envee-<uid>`) | `winio` или stdlib (Phase 3) |

**В MVP**: только UNIX socket. Windows tier 3 = без daemon, standalone only.

### File watching

| OS | Library | Notes |
|---|---|---|
| macOS | `fsnotify` → FSEvents | Works well |
| Linux | `fsnotify` → inotify | Works well, max 5000 watches default |
| Windows | `fsnotify` → ReadDirectoryChangesW | Phase 3 |

### OS keyring (per ADR-009)

| OS | Backend | Library |
|---|---|---|
| macOS | Keychain | `zalando/go-keyring` |
| Linux | Secret Service (GNOME Keyring / KWallet) | `zalando/go-keyring` + D-Bus |
| Windows | Credential Manager | `zalando/go-keyring` (Phase 3) |

**В MVP**: macOS + Linux. Windows tier 3 = без OS keyring, файловый cache в `XDG_DATA_HOME` (с warning).

### Path separators в config

Forward slashes везде, normalize при resolve:

```toml
[env]
SCRIPT_PATH = "{{config_root}}/scripts/run.sh"
DATA_DIR = "{{config_root}}/data"
```

В resolved env на Windows = `C:\Users\alice\work\myproj\scripts\run.sh`. На macOS/Linux = `/Users/alice/work/myproj/scripts/run.sh`.

**Conversion**: через `filepath.FromSlash` (Go stdlib).

### Home directory

| OS | Env var | Library |
|---|---|---|
| macOS | `$HOME` | `os.UserHomeDir()` |
| Linux | `$HOME` | `os.UserHomeDir()` |
| Windows | `%USERPROFILE%` | `os.UserHomeDir()` |

### XDG dirs

| OS | XDG defaults |
|---|---|
| macOS | `$HOME/.config`, `$HOME/.local/share`, `$TMPDIR` (per-user) |
| Linux | `$XDG_CONFIG_HOME` (default `$HOME/.config`), same |
| Windows | `%APPDATA%` (Roaming), `%LOCALAPPDATA%` |

**Library**: `github.com/adrg/xdg` (cross-platform XDG).

## CGO и static binaries

**Политика**: `CGO_ENABLED=0` для **всех** release builds.

Исключения:
- **Тесты** в CI: разрешаем cgo для race detector.
- **WASM runtime** (`wazero`) — pure Go, OK.
- **Plugin SDK** — pure Go, OK.

**Static linking**: `-ldflags '-s -w -extldflags "-static"'`.

**Результат**: single static binary, ~10-12 MB, no runtime dependencies.

## CI matrix

GitHub Actions:

```yaml
strategy:
  matrix:
    include:
      # Tier 1
      - os: macos-latest,    arch: amd64
      - os: macos-latest,    arch: arm64
      - os: ubuntu-latest,   arch: amd64
      - os: ubuntu-latest,   arch: arm64
      # Tier 2
      - os: alpine,          arch: amd64
      - os: ubuntu-20.04,    arch: amd64
      # Tier 3 (smoke tests only)
      - os: windows-latest,  arch: amd64, experimental: true
```

Каждый job:
1. Checkout, setup Go 1.24.
2. `go mod download`.
3. `go build -trimpath -ldflags="-s -w" ./cmd/envee` (и другие бинари).
4. `go test -race -shuffle=on -coverprofile=... ./...`.
5. `golangci-lint run`.
6. **Smoke test**: запустить собранный бинарь, проверить exit codes.

**Windows experimental**: build OK, но без race detector, без secret plugins (Keyring API differs). Smoke test: `envee --version`, `envee init pwsh | Out-Null`.

## Homebrew tap structure

`github.com/baken/homebrew-tap` (отдельный репо):

```
Formula/
  envee.rb                      # main formula
  envee-plugin-op.rb            # 1Password plugin
  envee-plugin-aws.rb
  ...
```

**Per-plugin Homebrew formula** — решает проблему "плагины — отдельные пакеты" (per ADR-007).

**Main formula** (`envee.rb`) — generated by GoReleaser через шаблон:

```ruby
class Envee < Formula
  desc "Per-directory environment variable manager"
  homepage "https://envee.dev"
  url "https://github.com/baken667/envee/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "<computed-by-goreleaser>"
  license "MIT"
  head "https://github.com/baken667/envee.git", branch: "main"

  depends_on "go" => :build

  def install
    system "go", "build", *std_go_args(ldflags: "-s -w"), "./cmd/envee"
    bin.install "envee"
    
    # Completions
    bash_completion.install "completions/envee.bash" => "envee"
    zsh_completion.install "completions/envee.zsh" => "_envee"
    fish_completion.install "completions/envee.fish"
    
    # Man pages
    man1.install Dir["man/man1/*.1"]
    
    # Shell hooks (для пользователя)
    pkgshare.install "stdlib"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/envee --version")
    
    # Init smoke test
    output = shell_output("#{bin}/envee init bash")
    assert_match "_envee_hook", output
  end
end
```

**Plugin formula** (`envee-plugin-op.rb`):

```ruby
class EnveePluginOp < Formula
  desc "1Password secret provider for envee"
  homepage "https://envee.dev/plugins/op"
  url "https://github.com/baken667/envee-plugins/archive/refs/tags/op-v1.0.0.tar.gz"
  sha256 "..."
  license "MIT"

  depends_on "envee"
  depends_on "1password-cli"

  def install
    system "go", "build", *std_go_args(ldflags: "-s -w"), "./op"
    bin.install "op" => "envee-plugin-op"
  end

  test do
    assert_match "1password", shell_output("#{bin}/envee-plugin-op metadata")
  end
end
```

## Distribution channels (per OS)

| Channel | macOS | Linux | Windows |
|---|---|---|---|
| Homebrew | ✅ primary | ✅ homebrew-on-linux | ❌ |
| apt | ❌ | ✅ (Phase 2) | ❌ |
| dnf/yum | ❌ | ✅ (Phase 2) | ❌ |
| pacman | ❌ | community (AUR) | ❌ |
| snap | ❌ | ✅ (Phase 2) | ❌ |
| scoop | ❌ | ❌ | ✅ (Phase 3) |
| chocolatey | ❌ | ❌ | ✅ (Phase 3) |
| winget | ❌ | ❌ | ✅ (Phase 3) |
| `go install` | ✅ | ✅ | ✅ |
| Docker image | ✅ (linux/amd64, linux/arm64) | ✅ | ⚠️ |
| Static tarball | ✅ | ✅ | ✅ |

## Docker

`ghcr.io/baken/envee:latest` — multi-arch (linux/amd64, linux/arm64).

```dockerfile
FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/envee ./cmd/envee

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /out/envee /usr/local/bin/
ENTRYPOINT ["envee"]
```

Тегнутые releases: `:0.1.0`, `:0.1`, `:0`, `:latest`.

## Последствия

### Положительные

- Single static binary — простая дистрибуция.
- macOS + Linux покрывают 95% user'ов direnv.
- Homebrew — primary channel, дёшево в обслуживании.
- Docker image для CI usage.

### Отрицательные

- Windows tier 3 = без daemon, без OS keyring. User на Windows → WSL.
- apt/rpm/snap — Phase 2 (отложено, чтобы не размазывать ресурсы).
- Snap/sandboxed environments могут ломать inotify/UNIX socket.

### Нейтральные

- Per-OS shell hooks — тестирование на 5 shells × 3 OS = 15 конфигураций в CI. Manageable.
- Plugin'ы — отдельные пакеты, своя release cadence.
