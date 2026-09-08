# ADR-013: Миграция с .envrc — `envee import` + compatibility mode

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как user'ам перейти с direnv на envee без большого рефакторинга

## Контекст

У user'ов уже есть `.envrc` файлы в проектах. Мы хотим:
1. Не заставлять user'ов делать big-bang migration.
2. Поддержать постепенный переход (файл за файлом, проект за проектом).
3. Дать удобный инструмент для конвертации 80% cases автоматически.

## Решение

### Три стратегии миграции

#### 1. `envee import` — автоматическая конвертация

```bash
$ cd /Users/alice/work/myproj  # has .envrc
$ envee import .envrc
Converting .envrc → envee.toml...

✓ Parsed 7 export statements
✓ Parsed 3 PATH_add calls
✓ Parsed 2 dotenv references
⚠ Found 1 use_nix call: requires WASM script (see ./scripts/nix-shell.wasm)
⚠ Found 1 bash loop: requires WASM script (manual review needed)

Generated: envee.toml (imported)
Backup:    .envrc.backup

Next steps:
  1. Review envee.toml
  2. Run `envee trust`
  3. Add `envee.toml` to git
  4. (Optional) Remove .envrc
```

### 2. Compatibility mode — `envee` читает `.envrc` если `envee.toml` нет

В Tier 1 OS (macOS/Linux) — если в cwd нет `envee.toml`, но есть `.envrc`, **envee** warning'ит и делегирует к direnv (если установлен):

```
[envee] ⚠ .envee.toml not found, but .envrc present.
[envee]   Run `envee import .envrc` to migrate.
[envee]   Falling back to direnv for compatibility.
```

Это позволяет установить envee рядом с direnv, мигрировать проект за проектом.

**Реализация**:
```go
// internal/resolver/discovery.go
func (r *Resolver) FindConfig() (path string, kind string) {
    if exists, _ := fileExists(filepath.Join(r.cwd, "envee.toml")); exists {
        return filepath.Join(r.cwd, "envee.toml"), "envee"
    }
    if exists, _ := fileExists(filepath.Join(r.cwd, ".envrc")); exists {
        return filepath.Join(r.cwd, ".envrc"), "envrc-compat"
    }
    // walk up parents...
    return "", ""
}
```

Когда `kind == "envrc-compat"`, envee вызывает `direnv export $SHELL` subprocess и проксирует результат.

### 3. Standalone direnv-replacement — `envee` полностью заменяет direnv

User снимает direnv с машины, ставит envee, делает `envee import` для всех `.envrc` файлов. Один weekend-проект.

## `envee import` — что умеет

### Автоматически конвертируется

| Direnv construct | Envee equivalent | Уверенность |
|---|---|---|
| `export X=Y` | `X = "Y"` | 100% |
| `export X=$Y` | `X = "{{env.Y}}"` | 100% |
| `export X="multi-line\ntext"` | TOML multi-line basic string | 100% |
| `export X=$(cmd)` | `X = { script = "./script.wasm" }` + generated WASM stub | 50% (auto-stub) |
| `PATH_add bin` | `_.path = ["./bin", "{{config_root}}/bin"]` | 100% (heuristic) |
| `PATH_add $PWD/bin` | `_.path = ["{{config_root}}/bin"]` | 100% |
| `dotenv` | `_.file = ".env"` | 100% |
| `dotenv .env.local` | `_.file = ".env.local"` | 100% |
| `source_env .envrc.shared` | requires manual: `_.source = ".envrc.shared"` (note: not bash!) | 50%, manual review |
| `source_env_if_exists .envrc.private` | `_.file = ".envrc.private"` (if dotenv format) | 50% |
| `export_env_if_exists .env` | `_.file = ".env"` (with `required = false`) | 100% |
| `layout python` | `_.tool.python = "venv"` (Phase 3) | 0%, manual |
| `layout node` | `_.tool.node = true` (Phase 3) | 0%, manual |
| `use nix` | `_.script = "./nix-shell.wasm"` (WASM stub) | 30%, manual |
| `use flake` | `_.script = "./flake.wasm"` (WASM stub) | 30%, manual |
| `watch_file X` | `watch = ["X"]` (top-level) | 100% |
| `source_up` | (handled via parent file search) | 100% |
| `source_up_if_exists` | (default behavior) | 100% |
| `log_status X` | (no equivalent, use comments) | 0%, manual |
| Bash if/else/case | `_.script` (WASM) | 30%, generated stub |
| Bash for/while | `_.script` (WASM) | 30%, generated stub |
| `export $(cat .env | xargs)` | `_.file = ".env"` | 100% |
| `eval "$(op signin ...)"` | `_.secret.X = { source = "op", ... }` | 80% (heuristic) |

### Генерирует stubs

Для сложных bash-конструкций `envee import` создаёт **WASM-stub** на Rust + помечает `# MANUAL REVIEW NEEDED`:

```rust
// scripts/imported-from-envrc-001.rs
// AUTO-GENERATED from .envrc — please review and implement logic
#![no_std]
#![no_main]

#[no_mangle]
pub fn _start() {
    // TODO: original bash was:
    //   if [[ "$OSTYPE" == "darwin"* ]]; then
    //     export SED="gsed"
    //   else
    //     export SED="sed"
    //   fi
    //
    // Implement this in envee-script-sdk and return JSON patches.
    envee_script_sdk::placeholder("imported-from-envrc-001");
}
```

### Сохраняет оригинал

```bash
.envrc.backup    # копия оригинала
```

User может `diff .envrc .envrc.backup` чтобы проверить, что мы не потеряли ничего.

## Поведение compatibility mode

```bash
# В cwd без envee.toml, но с .envrc
$ envee status
[envee] No envee.toml found.
[envee] Falling back to direnv (.envrc present).
[envee] To migrate: `envee import .envrc`

# Прокси к direnv
$ envee eval bash
$(direnv export bash)   # forward as-is
```

**Внутри**:
```go
// internal/cli/eval.go
func runEval(shell string) error {
    cfg, err := resolver.FindConfig()
    if err != nil { return err }
    
    if cfg.Kind == "envrc-compat" {
        log.Warn("envee.toml not found, using direnv (.envrc)")
        return proxyToDirenv(shell, cfg.Path)
    }
    
    // ... normal flow
}
```

**`proxyToDirenv`**:
```go
func proxyToDirenv(shell, envrcPath string) error {
    cmd := exec.Command("direnv", "export", shell)
    cmd.Stderr = os.Stderr
    out, err := cmd.Output()
    if err != nil {
        return fmt.Errorf("direnv failed: %w", err)
    }
    fmt.Print(string(out))
    return nil
}
```

## Trade-offs

| Аспект | Auto-import | Compatibility mode | Standalone replace |
|---|---|---|---|
| Усилия user'а | 1 команда | 0 (но warning) | weekend |
| Safety | высокая (manual review) | средняя | средняя |
| Совместимость с direnv | не нужна | нужна (fallback) | не нужна |
| Lock-in | нет (можно откатить) | средняя | полная |
| Best for | новые user'ы | existing user'ы, gradual | early adopters |

## Когда `envee import` НЕ работает (manual)

1. **Bash `eval`/dynamic code generation** — не парсится.
2. **Сложные pipelines** с `awk`/`sed` — не конвертируются.
3. **Conditional на основе $RANDOM, $(date), etc.** — нужно переписать в WASM.
4. **Multiple `.envrc` с наследованием** (`source_env` chain) — частично.

Для этих случаев: пишем `.envee.toml` руками + WASM-скрипты. Постепенно.

## Migration guide (для README)

```markdown
## Migration from direnv

### Quick start

```bash
# 1. Install envee alongside direnv
brew install baken/tap/envee

# 2. Test in a single project
cd ~/work/myproj
envee status  # uses .envrc via fallback
envee import .envrc  # generates envee.toml
# Review envee.toml
envee trust
envee eval bash  # test the new setup

# 3. Once happy, remove direnv hook
# Edit ~/.zshrc, remove: eval "$(direnv hook zsh)"
# Add: eval "$(envee init zsh)"

# 4. Optional: uninstall direnv
brew uninstall direnv
```

### Per-project migration

Repeat step 2 for each project. Old `.envrc` files stay until you delete them.
```

## Поддержка `direnv.toml` (Phase 2)

Если user хочет настроить envee, но не хочет трогать `.envrc` сразу — может положить `envee.toml` рядом с `.envrc`, envee прочитает `envee.toml`, **игнорируя** `.envrc`. Полная замена в этом проекте.

## `.envrc.compat.toml` (escape hatch)

Если есть проект, который **нельзя** мигрировать (legacy bash, 1000 строк), можно:

```toml
# .envrc.compat.toml
[legacy]
source_bash = ".envrc"   # exec `bash -c '. .envrc && env'`, diff it
quota = "1s"
```

Envee запустит `bash -c 'source .envrc && env -0'` в sandbox, diff с current env, export. **Медленнее** (per ADR-006 почему), но работает.

**Tradeoff**: legacy mode = re-introduce RCE через bash. Default = warning, opt-in через `--allow-legacy-bash`.

## `envee-doctor` — diagnostic tool

```bash
$ envee doctor
✓ envee.toml found at /Users/alice/work/myproj/envee.toml
✓ Trusted (sha256:abc...)
✓ Profile: dev (from $ENVEE_PROFILE)
✓ All required vars present
⚠ 2 secrets using stale cache
✓ Plugin 'op' found
✗ Plugin 'aws' not found (required by DATABASE_BACKUP_KEY)

Diagnostics:
  - To refresh secrets: envee invalidate --secret=<name>
  - To install aws plugin: brew install baken/tap/envee-plugin-aws
```

## Последствия

### Положительные

- Низкий порог входа для existing user'ов direnv.
- Compatibility mode позволяет gradual migration.
- `envee import` экономит время на 80% common cases.
- Не нужно поддерживать `.envrc` natively (только compat fallback).

### Отрицательные

- `.envrc.compat.toml` — re-introduce bash RCE, нужен explicit opt-in.
- Dual install (envee + direnv) — overhead для compatibility testing.
- `envee import` — не 100% покрытие, user всё равно делает manual review.

### Нейтральные

- Compatibility mode — opt-in (default = warning при `.envrc` без `envee.toml`).
- Per-project migration tracking (out of scope MVP, Phase 2).
