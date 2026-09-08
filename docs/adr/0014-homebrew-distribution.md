# ADR-014: Homebrew Distribution — primary channel, GoReleaser + custom tap

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как обеспечить frictionless install + auto-update через Homebrew

## Контекст

Homebrew — стандарт де-факто для CLI tools на macOS и Linux. Преимущества:
- `brew install` = 1 команда, без скачивания бинарей.
- `brew upgrade` = auto-update.
- Bottle (pre-compiled binary) = быстрая установка.
- Зависимости (например, `1password-cli` для `envee-plugin-op`) декларируются.

У direnv есть [официальный formula](https://github.com/Homebrew/homebrew-core/blob/master/Formula/d/direnv.rb) в `homebrew-core`. Это **gold standard**, но требует PR review каждый релиз — overhead.

Альтернативы для homebrew distribution:
- **homebrew-core** — strict review, ~1-2 недели на PR, prestige.
- **Custom tap** (`baken/tap`) — мгновенный publish, полный контроль.

## Решение

**Custom tap**: `github.com/baken/homebrew-tap` для MVP. **Подача в homebrew-core** — после стабилизации API (v1.0+).

### Структура tap

```
github.com/baken/homebrew-tap/
├── README.md
├── .github/
│   └── workflows/
│       └── audit.yml                  # auto-audit formulae
├── Formula/
│   ├── envee.rb                       # core
│   ├── envee-plugin-op.rb             # 1Password
│   ├── envee-plugin-aws.rb            # AWS
│   ├── envee-plugin-vault.rb          # Vault
│   ├── envee-plugin-sops.rb           # SOPS
│   ├── envee-plugin-age.rb            # age
│   ├── envee-plugin-bw.rb             # Bitwarden
│   └── envee-plugin-keyring.rb        # OS keyring
└── scripts/
    └── update-formulae.sh             # auto-update from upstream
```

### GoReleaser конфиг

`.goreleaser.yaml` в основном репо:

```yaml
version: 2

project_name: envee

# Repository для brew tap auto-update
tap:
  owner: baken
  name: homebrew-tap
  branch: main
  token: "{{ .Env.HOMEBREW_TAP_TOKEN }}"

builds:
  - id: envee
    main: ./cmd/envee
    binary: envee
    env:
      - CGO_ENABLED=0
    goos:
      - darwin
      - linux
      - windows
    goarch:
      - amd64
      - arm64
      - arm
    goarm:
      - "7"
    ignore:
      - goos: windows
        goarch: arm
    flags:
      - -trimpath
      - -buildvcs=false
    ldflags:
      - -s -w
      - -X main.version={{.Version}}
      - -X main.commit={{.Commit}}
      - -X main.date={{.Date}}

  - id: enveed
    main: ./cmd/enveed
    binary: enveed
    # ... same matrix

  - id: completions
    builder: cmd/completions-gen  # internal tool generating shell completions
    binary: envee-completions
    # ... 

archives:
  - id: envee-archive
    builds: [envee, enveed]
    name_template: "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}"
    format: tar.gz
    files:
      - README.md
      - LICENSE
      - CHANGELOG.md
      - completions/*
      - manpages/*
    format_overrides:
      - goos: windows
        format: zip

nfpms:
  - id: packages
    package_name: envee
    builds: [envee]
    formats:
      - deb
      - rpm
      - apk
    maintainer: "Bauyrzhan Akhmetov <baken@example.com>"
    description: "Per-directory environment variable manager"
    homepage: "https://envee.dev"
    license: "MIT"
    dependencies:
      - bash
    bindir: /usr/bin
    section: utils
    priority: optional

brews:
  - id: envee
    tap:
      owner: baken
      name: homebrew-tap
    name: envee
    homepage: "https://envee.dev"
    description: "Per-directory environment variable manager"
    license: "MIT"
    install: |
      bin.install "envee"
      bin.install "enveed"
      bash_completion.install "completions/envee.bash" => "envee"
      zsh_completion.install "completions/envee.zsh" => "_envee"
      fish_completion.install "completions/envee.fish"
      man1.install Dir["manpages/*.1"]
      pkgshare.install "stdlib"
    test: |
      assert_match version.to_s, shell_output("#{bin}/envee --version")
      output = shell_output("#{bin}/envee init bash")
      assert_match "_envee_hook", output
    dependencies: []
    # Pre-built bottles uploaded to GitHub Releases
    custom_block: |
      desc "Daemon process for envee"
    caveats: |
      To enable envee in your shell, add one of these to your config:
        bash:  eval "$(envee init bash)"
        zsh:   eval "$(envee init zsh)"
        fish:  envee init fish | source

  - id: envee-plugin-op
    tap:
      owner: baken
      name: homebrew-tap
    name: envee-plugin-op
    homepage: "https://envee.dev/plugins/op"
    description: "1Password secret provider for envee"
    license: "MIT"
    install: |
      bin.install "envee-plugin-op"
    dependencies:
      - envee
      - 1password-cli

# Plugins — отдельная секция, каждая Formula генерируется
plugin_brews:
  - id: envee-plugin-op
    # similar config, но из ./plugins/op/

release:
  github:
    owner: baken
    name: envee
  prerelease: auto
  draft: false
  name_template: "v{{.Version}}"
  header: |
    ## Envee {{.Version}}
    Released: {{.Date}}
  footer: |
    **Full Changelog**: https://github.com/baken667/envee/compare/{{ .PreviousTag }}...{{ .Tag }}

changelog:
  use: git
  groups:
    - title: "🚀 Features"
      regexp: '^.*?feat(\([[:word:]]+\))??!?:.*$'
      order: 0
    - title: "🐛 Bug Fixes"
      regexp: '^.*?fix(\([[:word:]]+\))??!?:.*$'
      order: 1
    - title: "🧰 Maintenance"
      regexp: '^.*?(chore|docs|style|refactor|perf|test)(\([[:word:]]+\))??!?:.*$'
      order: 2
  filters:
    exclude:
      - '^Merge pull request'
      - '^Merge branch'

sign:
  artifacts: all
  cmd: cosign
  artifacts: checksum
  signature: ${artifact}.sig
  key: "{{ .Env.COSIGN_KEY }}"

# SBOM generation
sboms:
  - id: source-sbom
    artifacts: archive
  - id: binary-sbom
    artifacts: binary
```

### Auto-update flow

При `git tag v0.1.0 && git push --tags`:

1. **GitHub Action** `release.yml` triggers.
2. **GoReleaser** runs, builds all artifacts (binaries, archives, debs, rpms, apks).
3. **GoReleaser** uploads to `https://github.com/baken667/envee/releases/tag/v0.1.0`.
4. **GoReleaser** opens PR в `baken/homebrew-tap`:
   - `Formula/envee.rb` updated с new version + SHA256.
   - `Formula/envee-plugin-op.rb` updated.
   - PR title: "envee 0.1.0".
5. **CI в homebrew-tap** запускает `brew audit --new --strict envee` (проверка syntax/style).
6. **Maintainer** review'ит и merges (или auto-merge если audit passes + tests pass).
7. **Users** делают `brew upgrade envee` и получают новую версию.

**Bottles**: GoReleaser builds bottles для каждой macOS/Linux комбинации, uploads в GitHub Release, и в `envee.rb` появится:

```ruby
sha256 cellar: :any_skip_relocation, arm64_sonoma: "abc..."
sha256 cellar: :any_skip_relocation, ventura:      "def..."
sha256 cellar: :any_skip_relocation, x86_64_linux: "ghi..."
```

`brew install envee` скачивает bottle (5MB), не компилирует из source. **Очень быстро**.

### Signing & SLSA provenance

**Cosign** (sigstore) подписывает:
1. Каждый binary (detached signature).
2. Каждый archive.
3. Checksum file.

**SLSA provenance attestation** — `goreleaser` через `slsa-github-generator`:

```yaml
# .github/workflows/release.yml
- uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic.yml@v2
  with:
    base64-subjects: "${{ steps.hash.outputs.hashes }}"
    provenance-name: "envee.intoto.jsonl"
```

**Users verify** (опционально):
```bash
$ cosign verify-blob \
    --signature envee_darwin_arm64.tar.gz.sig \
    --certificate-identity-regexp 'https://github.com/baken667/envee' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    envee_darwin_arm64.tar.gz
```

### Homebrew tap аудит (в tap repo)

`.github/workflows/audit.yml`:

```yaml
name: Audit formulae
on:
  pull_request:
    paths: ['Formula/**']
  push:
    branches: [main]

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Homebrew
        run: |
          /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      - name: Audit
        run: brew audit --strict --new Formula/*.rb
      - name: Test install
        run: |
          for f in Formula/*.rb; do
            brew install --build-from-source "$f"
            brew test "$f"
          done
```

### Когда переходить в homebrew-core

**Когда**:
- v1.0.0 (semver stable API).
- > 1000 GitHub stars (social proof).
- Active community (issues addressed within days).
- Tests pass on homebrew-core's CI.
- Maintainer (Bauyrzhan) готов к PR review process.

**Процесс**:
1. Tag v1.0.0, publish to custom tap.
2. Submit PR to `homebrew-core`.
3. Address review comments (1-2 weeks).
4. Merge → users install via `brew install envee` (no tap needed).
5. Maintain custom tap for pre-release channels (HEAD, beta).

**После перехода**:
- Custom tap → only `envee --HEAD`, `envee --beta`.
- `baken/envee` = stable channel через homebrew-core.

## Multi-arch bottles

```ruby
# В envee.rb после GoReleaser
bottle do
  sha256 cellar: :any_skip_relocation, arm64_sonoma:  "abc123..."
  sha256 cellar: :any_skip_relocation, arm64_ventura: "def456..."
  sha256 cellar: :any_skip_relocation, x86_64_sonoma: "ghi789..."
  sha256 cellar: :any_skip_relocation, x86_64_ventura: "jkl012..."
  sha256 cellar: :any_skip_relocation, x86_64_linux:  "mno345..."
  sha256 cellar: :any_skip_relocation, aarch64_linux: "pqr678..."
end
```

`:any_skip_relocation` — bottle работает на любой install location (relocatable). Подходит для нас (нет hardcoded paths).

## Тестирование

В tap CI:
1. `brew install --build-from-source envee` (компилирует, проверяет build).
2. `brew test envee` (запускает `envee --version`, `envee init bash`).
3. `brew audit --strict --new envee` (проверяет style).
4. `brew style envee` (доп. style checks).

В основном репо (`envee`):
1. CI build на 6 OS/arch комбинациях.
2. `go test -race -shuffle=on ./...`.
3. Smoke test: `envee eval bash` в fixture project.
4. `golangci-lint`.
5. После merge в main: GoReleaser **dry-run** (build artifacts locally, не публикует).

## Мониторинг

**GitHub**:
- `baken/envee` repo: stars, issues, PR activity.
- `baken/homebrew-tap` repo: download stats (через `homebrew-core` API).

**Homebrew analytics** (opt-in):
- `brew install` / `brew upgrade` / `brew uninstall` events.
- Анонимная статистика → `https://formulae.brew.sh/analytics/install/30d/`.

**Sentry / error tracking** (opt-in, через `ENVEE_TELEMETRY=1`):
- Crash reports (без PII, без env values).
- Usage events (`envee eval` 1000 times, `envee trust` 5 times).

## Docs site

`envee.dev` (через GitHub Pages + Cloudflare):
- Landing page: `index.html` (из `docs/index.html`).
- Docs: `https://envee.dev/docs/...` (mkdocs → static).
- Schema: `https://envee.dev/schemas/envee-v1.json`.

**CI**:
```yaml
- name: Deploy docs
  uses: peaceiris/actions-gh-pages@v3
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    publish_dir: ./public
```

## Последствия

### Положительные

- `brew install baken667/tap/envee` = 1 команда → install в < 30 сек.
- Автоматические updates через `brew upgrade`.
- Bottles = быстрая установка (без компиляции).
- Подписи cosign + SLSA provenance = supply chain security.
- Custom tap → полный контроль, нет PR bottleneck.

### Отрицательные

- Custom tap ≠ homebrew-core → меньше discoverability (`brew search` не находит).
- Bottles = дополнительный storage на GitHub Releases (~50MB на версию).
- Cosign keys нужно ротировать.
- Multi-arch testing matrix — 6+ комбинаций.

### Нейтральные

- Eventually migration в homebrew-core (v1.0+).
- Per-plugin formulae (7+ formulae для разных secret providers).
- Telemetry opt-in, не default.
