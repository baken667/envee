# ADR-018: CLI Surface — cobra-based, композируемая, consistent

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как выглядит CLI в плане subcommands, флагов, output

## Контекст

CLI — это user-facing surface. Должен быть:
- **Понятный** — `envee --help` показывает всё.
- **Консистентный** — `--json` работает везде.
- **Композируемый** — `envee eval bash | source` работает.
- **Discoverable** — `envee <TAB>` автодополняет.

## Решение

**Cobra + pflag** (стандарт в Go-экосистеме, используется в `kubectl`, `hugo`, `gh`).

### Top-level commands

```
envee — Per-directory environment variable manager

Usage:
  envee [command]

Commands:
  init         Generate shell hook code
  trust        Trust envee.toml (review + approve)
  deny         Deny envee.toml (explicit block)
  status       Show current state
  resolve      Compute and print resolved env
  eval         Print shell-specific export/unset commands
  diff         Show env changes since last eval
  exec         Run a command with loaded env
  check        Static analysis of envee.toml
  doctor       Health diagnostics
  debug        Collect diagnostic dump
  completion   Generate shell completions
  version      Show envee version
  help         Show help for any command
  plugin       Manage plugins
  daemon       Manage enveed daemon
  telemetry    Telemetry settings
  upgrade      Upgrade envee.toml to current schema

Flags:
  -h, --help            help for envee
  -V, --version         version (alias for `envee version`)
  -v, --verbose         increase log verbosity
  -q, --quiet           suppress non-essential output
  --log-level string    log level: trace|debug|info|warn|error
  --log-format string   log format: text|json (default text)
  --color string        color mode: auto|always|never
  --config string       path to envee.toml (default: auto-discover)
  --profile string      profile to use (overrides $ENVEE_PROFILE)
  --no-color            disable color output (alias for --color=never)
  --no-telemetry        disable telemetry for this invocation
  --debug               enable debug mode
```

### Subcommand: `envee init`

```bash
envee init <shell>     # bash, zsh, fish, nu, pwsh, elvish
envee init --cached    # write to cache file, source from there
```

Output: shell code на stdout. User pipes в eval или source.

### Subcommand: `envee trust`

```bash
envee trust [path]            # trust file at path (or current)
envee trust --sign --key <key>  # sign trust entry
envee trust --ttl=24h          # time-bounded trust
envee trust --secrets-only     # only re-review secret sources
envee trust --yes              # non-interactive (auto-approve)
envee trust --remove [path]    # remove trust entry
```

### Subcommand: `envee status`

```bash
envee status                  # human-readable
envee status --json           # machine-readable
envee status --show-secrets   # reveal secrets (requires confirm)
envee status --profile        # show profile info
envee status --trust          # show trust store contents
envee status --plugins        # show discovered plugins
envee status --daemon         # show daemon status
```

### Subcommand: `envee resolve`

```bash
envee resolve                       # text output
envee resolve --json                # JSON
envee resolve --shell=bash          # shell-escaped
envee resolve --include-os-env      # include OS env (default)
envee resolve --no-os-env           # only envee-managed vars
envee resolve --dry-run             # don't resolve secrets
envee resolve --profile=prod        # override profile
```

### Subcommand: `envee eval`

```bash
envee eval <shell>                  # bash, zsh, fish, nu, pwsh, elvish
envee eval --quiet bash             # suppress all non-error output
envee eval --no-cache bash          # bypass daemon cache
envee eval --no-color bash          # disable color in errors
```

### Subcommand: `envee diff`

```bash
envee diff <shell>                  # show env changes vs current
envee diff --json                   # JSON output
```

### Subcommand: `envee exec`

```bash
envee exec <shell> -- cmd [args...]  # run cmd with loaded env
envee exec --profile=prod -- npm test
envee exec --quiet -- go run .
```

### Subcommand: `envee check`

```bash
envee check [path]                  # static analysis
envee check --strict                # warnings as errors
envee check --json                  # JSON output
```

### Subcommand: `envee doctor`

```bash
envee doctor                        # quick health check
envee doctor --fix                  # auto-fix safe issues
envee doctor --verbose              # detailed diagnostics
```

### Subcommand: `envee plugin`

```bash
envee plugin list                   # discovered plugins
envee plugin list --json            # JSON output
envee plugin info <name>            # metadata for plugin
envee plugin install <name>         # via brew/go
envee plugin remove <name>          # uninstall
envee plugin test <name>            # test plugin connectivity
```

### Subcommand: `envee daemon`

```bash
envee daemon status                 # is it running?
envee daemon start                  # start in background
envee daemon stop                   # stop
envee daemon restart                # restart
envee daemon logs                   # tail logs
envee daemon disable                # disable for this user
envee daemon enable                 # enable (default)
```

### Subcommand: `envee telemetry`

```bash
envee telemetry status              # on/off
envee telemetry enable              # opt-in
envee telemetry disable             # opt-out
envee telemetry delete              # delete collected data
```

### Subcommand: `envee upgrade`

```bash
envee upgrade                       # upgrade envee.toml schema
envee upgrade --from 0.4 --to 0.5   # explicit version migration
envee upgrade --dry-run             # show changes, don't apply
envee upgrade --backup              # keep .envee.toml.backup
```

## Глобальные флаги

Все subcommands поддерживают:

| Flag | Description |
|---|---|
| `--config <path>` | Override config file location |
| `--profile <name>` | Override profile selection |
| `--log-level <level>` | trace/debug/info/warn/error |
| `--log-format <fmt>` | text/json |
| `--color <mode>` | auto/always/never |
| `--quiet / -q` | Suppress non-essential output |
| `--verbose / -v` | Increase verbosity |
| `--debug` | Debug mode (stacktraces, more logs) |
| `--no-telemetry` | Disable telemetry for this invocation |

## Output conventions

**stdout**: machine-readable output (env vars, JSON, shell commands).
**stderr**: human-readable info (logs, progress, errors).

```bash
$ envee eval bash > eval.sh 2> debug.log
$ envee resolve --json | jq '.env.DATABASE_URL'
$ envee status 2>&1 | less
```

**Exit codes** (per ADR-017):
- 0 = success
- 1-6 = various errors
- 64-78 = sysexits.h

## Shell completions

Генерируются автоматически (cobra встроенная поддержка):

```bash
# В formula
bash_completion.install "completions/envee.bash" => "envee"
zsh_completion.install "completions/envee.zsh" => "_envee"
fish_completion.install "completions/envee.fish"
```

**PowerShell completion** — через `Register-ArgumentCompleter` (Phase 3).

## Aliases (v2.x, не MVP)

Для удобства — короткие алиасы:

| Alias | Full command |
|---|---|
| `envee r` | `envee resolve` |
| `envee e` | `envee eval` |
| `envee s` | `envee status` |
| `envee t` | `envee trust` |
| `envee d` | `envee diff` |

**Не делаем** в MVP — вызывает путаницу. В v2.x, если попросят.

## Hidden commands (для testing/debugging)

- `envee _internal-foo` — prefix `_` → не показывается в help, completions.

Используем для:
- `envee _test-plugin-conn` — internal test command.
- `envee _print-cache` — dump cache contents.
- `envee _simulate-shell-eval` — для CI тестов shell hook logic.

## Backward compatibility

- **Adding flag**: backward compatible (старые scripts используют default).
- **Adding subcommand**: backward compatible.
- **Removing flag/subcommand**: **breaking**, только в major.
- **Changing flag behavior**: **breaking**, only in major, with deprecation period.
- **Changing output format**: **breaking** для `--json`, must be major.

## Examples (для `--help` output)

```bash
$ envee trust --help
Trust envee.toml (review + approve its content).

When you trust an envee.toml, you allow it to define environment variables
for your shell when you enter the directory. envee will compute a SHA-256
hash of the file's content and store it in your trust store. Any subsequent
change to the file will require re-trust.

Usage:
  envee trust [path] [flags]

Flags:
  -h, --help            help for trust
      --sign            sign trust entry with key
      --key string      path to signing key
      --ttl string      trust TTL (e.g., "24h", "7d", "never")
      --yes             auto-approve without interactive prompt
      --remove          remove trust entry instead of adding
      --secrets-only    only review secret sources (skip regular vars)

Examples:
  # Trust the envee.toml in the current directory:
  envee trust

  # Trust with a 24-hour expiration:
  envee trust --ttl=24h

  # Sign trust entry for sharing with team:
  envee trust --sign --key ~/.ssh/id_ed25519

  # Remove trust:
  envee trust --remove

Global Flags:
      --config string    path to envee.toml
      --profile string   profile to use
  -q, --quiet            suppress non-essential output
      --log-level string log level
```

## Cobra structure

```go
// cmd/envee/main.go
func main() {
    rootCmd := &cobra.Command{
        Use:   "envee",
        Short: "Per-directory environment variable manager",
        Long:  `envee loads environment variables from envee.toml when you enter a directory...`,
        Version: version,
        SilenceUsage: true,    // don't print usage on error
        SilenceErrors: false,  // print errors
    }
    
    rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "config file")
    rootCmd.PersistentFlags().StringVar(&profile, "profile", "", "profile")
    rootCmd.PersistentFlags().StringVar(&logLevel, "log-level", "warn", "log level")
    // ...
    
    rootCmd.AddCommand(
        newInitCmd(),
        newTrustCmd(),
        newDenyCmd(),
        newStatusCmd(),
        newResolveCmd(),
        newEvalCmd(),
        newDiffCmd(),
        newExecCmd(),
        newCheckCmd(),
        newDoctorCmd(),
        newDebugCmd(),
        newCompletionCmd(),
        newVersionCmd(),
        newPluginCmd(),
        newDaemonCmd(),
        newTelemetryCmd(),
        newUpgradeCmd(),
    )
    
    if err := rootCmd.Execute(); err != nil {
        os.Exit(1)
    }
}
```

## Configuration в Cobra

Cobra + Viper (или koanf) для default'ов:

```go
func initConfig() {
    if cfgFile != "" {
        viper.SetConfigFile(cfgFile)
    } else {
        viper.SetConfigName("envee")
        viper.SetConfigType("toml")
        viper.AddConfigPath(".")
        viper.AddConfigPath("$XDG_CONFIG_HOME/envee/")
    }
    
    viper.SetEnvPrefix("ENVEE")
    viper.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
    viper.AutomaticEnv()
    
    if err := viper.ReadInConfig(); err == nil {
        log.Debug("using config file", "path", viper.ConfigFileUsed())
    }
}
```

**Note**: viper используем **только** для CLI-уровневых настроек (log level, color mode), не для `envee.toml` resolve (это своя логика).

## Documentation

**Генерируется автоматически**:
- `envee --help` (cobra auto).
- `envee <cmd> --help`.
- `man envee` (cobra генерит man pages через `github.com/spf13/cobra/doc`).
- Markdown docs (`docs/reference/*.md`).

**CI job**:
```yaml
- name: Generate docs
  run: |
    go run ./cmd/gen-docs --output=docs/reference/
    git diff --exit-code docs/reference/  # fail if outdated
```

## Последствия

### Положительные

- Единообразный UX (cobra conventions).
- Богатые `--help` с примерами.
- Готовые completions для bash/zsh/fish.
- Легко добавлять новые subcommand'ы.
- Testable: каждая команда = функция, можно unit-тестировать.

### Отрицательные

- Cobra — overhead (но minor).
- Viper — complexity (если overused).
- 17 subcommands — много. Можно sub-group (envee plugin list, не envee list-plugins).

### Нейтральные

- Aliases — отложены в v2.x.
- Hidden commands — internal, не документируем.
