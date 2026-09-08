# Roadmap: A + B + C — eval, trust TUI, plugin SDK

> **Цель**: довести envee до состояния, в котором он реально работает end-to-end —
> загружает TOML, разрешает templates, диффует с OS env, выдаёт shell-команды,
> защищён trust-flow'ом, и расширяется через плагины (начинаем с `envee-plugin-env`).
>
> **Горизонт**: 2-3 недели при ~4-6 ч/день solo. Можно резать на milestone'ы.

## Стратегический обзор

```
        ┌─────────────────────────────────────────────────────────────┐
        │                  DEPENDENCY GRAPH                            │
        └─────────────────────────────────────────────────────────────┘

   A. eval (core)          B. trust TUI         C. plugin SDK + env
   ┌──────────────┐         ┌──────────────┐      ┌──────────────────┐
   │ T1.1 wire    │         │ T2.1 hash    │      │ T3.1 SDK pkg     │
   │ T1.2 file    │         │ T2.2 diff    │      │ T3.2 protocol    │
   │ T1.3 path    │         │ T2.3 prompt  │      │ T3.3 env plugin  │
   │ T1.4 profile │         │ T2.4 TUI     │      │ T3.4 wire        │
   │ T1.5 templates│        │ T2.5 gate    │      │ T3.5 cache       │
   │ T1.6 diff    │         └──────┬───────┘      └────────┬─────────┘
   │ T1.7 emit    │                │                       │
   │ T1.8 tests   │                │                       │
   └──────┬───────┘                │                       │
          │                        ▼                       ▼
          │              T2.6 eval-gate integration
          │              ┌──────────────────────┐
          │              │ eval refuses untrusted│
          │              │ envee.toml; shows TUI │
          │              └──────────┬───────────┘
          │                         │
          └─────────────────────────┘
                         │
                         ▼
            T4.1 e2e smoke on all examples
            T4.2 docs (README updates)
            T4.3 perf benchmarks vs direnv
            T4.4 v0.1.0 release prep
```

**Критический путь**: A → T2.5 (trust gate in eval) → T4.\*

**Параллелизуемо**:
- B (T2.1-T2.4) можно делать параллельно с A, до момента интеграции.
- C (T3.1-T3.3) — полностью параллельно с A и B; интеграция в конце.

---

## A. `envee eval` end-to-end

**Что это**: цепочка `load TOML → resolve directives → evaluate templates → diff with OS env → emit shell export/unset commands`. Сейчас все компоненты есть по отдельности, но не сшиты.

**Цель MVP-A**: `envee eval bash` в `examples/basic` правильно выдаёт export'ы для всех переменных из `envee.toml` + `.env`, с PATH из `_.path`, с shell-safe escaping.

### T1.1 — Wire `resolver.LoadAll` → `eval` command

**Что делаем**: реализовать `cli/eval.go` так, чтобы он:
1. Получал cwd (или `--config`-path).
2. Вызывал `resolver.New(cwd).LoadAll()` → `*config.Config`.
3. Проверял trust (пока: stub — всегда trusted; T2.5 сделаем полноценно).
4. Передавал в directive applier (T1.2) + template engine (T1.5).

**Файлы**:
- `internal/cli/eval.go` — реальная имплементация.
- `internal/cli/resolve.go` — то же, но text/JSON output.
- `internal/cli/status.go` — то же, но human-readable summary.

**Acceptance**:
- `envee eval bash` в `examples/basic` выводит НЕ `not yet implemented`, а реальный export-список.
- `--quiet` флаг работает.
- Exit code 0 при успехе, 4 при config error (per ADR-0017).

**Effort**: 0.5 дня.

### T1.2 — File directives (`_.file`)

**Что делаем**: новый пакет `internal/directive` с подпакетами. Начнём с `file.go`.

**Поведение**:
- `_.file = ".env"` → load `.env` (dotenv format) из `config_root`.
- `_.file = [{ path = ".env.local", redact = true }]` → load с redaction.
- `_.file = [{ path = ".env.json", format = "json" }]` → load JSON.
- `_.file = [{ path = ".env.yml", format = "yaml" }]` → load YAML.
- `_.file = [{ path = ".env.toml", format = "toml" }]` → load TOML.

**Файлы**:
- `internal/directive/directive.go` — `Apply(ctx, *config.Config) (*env.Map, error)` оркестратор.
- `internal/directive/file.go` — реализация `applyFile(ctx, ref) (*env.Map, error)`.
- `pkg/dotenv/parse.go` — перенос из `direnv/pkg/dotenv/parse.go` (BSD-licensed), чтобы не зависеть от external.

**Зависимости**:
- `gopkg.in/yaml.v3` — для YAML (уже есть в stdlib? нет, надо добавить).
- `github.com/BurntSushi/toml` — для TOML (уже в go.mod).
- `encoding/json` — stdlib.

**Edge cases**:
- File not found + `required = true` → error E012.
- File not found + `required = false` → skip silently.
- File with `expand = true` → interpolate `$VAR` references.
- Variable in file already defined in TOML `env` → file wins (lower priority layer, не file).
  - На самом деле: TOML `env` — highest, file — lower. Уточнить в логике.
- Cyclic file includes — запрещены, error.

**Acceptance**:
- `examples/basic/.env` загружается в env.
- `_.file` с redaction помечает все значения как redact.
- `_.file` с `format = "json"` парсит JSON.
- Несуществующий файл + `required = true` → fail с понятным message.

**Effort**: 1 день.

### T1.3 — Path directives (`_.path`)

**Что делаем**: применяем `_.path` к `$PATH` env var.

**Поведение**:
- `_.path = ["./bin"]` → prepend `./bin` (relative to `config_root`).
- `_.path = [{ path = "/abs/path", position = "append" }]` → append.
- `_.path = [{ path = "{{env.HOME}}/.local/bin" }]` → template expansion.

**Файлы**:
- `internal/directive/path.go`.

**Алгоритм**:
1. Resolve templates в path values.
2. Convert relative paths to absolute (от `config_root`).
3. Deduplicate (если `./bin` уже в PATH — не дублируем).
4. Prepend/append to existing $PATH.

**Acceptance**:
- PATH содержит `examples/basic/bin` после eval.
- Отсутствие дублей.
- Шаблоны в path раскрываются.

**Effort**: 0.5 дня.

### T1.4 — Profile selection

**Что делаем**: после merge всех configs, выбираем активный profile.

**Поведение** (per ADR-0010):
1. Если задан `--profile` flag → use it.
2. Иначе `$ENVEE_PROFILE` env var → use it.
3. Иначе `profile = "dev"` из `envee.toml` → use it.
4. Иначе — no profile (только base values).

**После выбора**:
- Применяем profile overlay: `cfg.Env` += `cfg.Profiles[active].Env` (deep merge).
- Apply extends: load other profiles first.
- Validate `required` vars: missing → error E008.

**Файлы**:
- `internal/resolver/profile.go` — `Resolve(cfg, name) (*config.Config, error)`.
- Обновить `internal/resolver/resolver.go` — использовать.

**Acceptance**:
- `ENVEE_PROFILE=prod envee eval bash` в `examples/multi-profile` подгружает prod-overlay.
- `required = ["DATABASE_URL"]` для prod → fail если DATABASE_URL не определена.
- `extends = ["common"]` — common грузится первым.

**Effort**: 1 день.

### T1.5 — Template evaluation in env merge

**Что делаем**: после merge profile, проходим по всем значениям env, ищем `{{...}}` patterns, раскрываем через `template.Engine`.

**Поведение**:
- Topological sort: variable с template вычисляется ПОСЛЕ variables, на которые ссылается.
- Circular dependency → error E007.
- `{{config_root}}` → `config_root` from `Context`.
- `{{profile}}` → active profile.
- `{{env.X}}` → first check resolved env, then OS env.

**Файлы**:
- `internal/directive/template.go` — оркестратор.
- `internal/template/eval.go` — extract dependencies, topo sort (новая функция в существующем пакете).

**Алгоритм**:
```go
// 1. Build dependency graph
deps := make(map[string][]string)
for k, v := range cfg.Env {
    deps[k] = extractTemplateVars(v.(string))
}

// 2. Topological sort
order, err := topoSort(deps)

// 3. Evaluate in order
ctx := &template.Context{ConfigRoot: ..., Profile: ..., OSEnv: osEnviron()}
for _, k := range order {
    rawVal := resolved[k]
    rendered, err := engine.Render(rawVal, ctx)
    resolved.Set(k, rendered)
    ctx.Env[k] = rendered  // for subsequent vars
}
```

**Acceptance**:
- `LOG_PATH = "{{config_root}}/logs/{{profile}}.log"` раскрывается.
- `{{env.HOME | default("/tmp")}}` работает.
- Цикл A→B→A → error E007.

**Effort**: 1.5 дня.

### T1.6 — Diff vs OS env

**Что делаем**: после построения `resolved env.Map`, считаем diff с `os.Environ()` (текущая shell env).

**Поведение**:
- Set: переменная в resolved, нет в OS env или другое значение.
- Unset: переменная в OS env с `redact = true` И помечена для сброса (через `value = false`).
- Ignore: `PATH` (обрабатывается отдельно через `_.path`), `SHLVL`, `_`, etc. (per direnv's `IgnoredKeys`).

**Файлы**:
- `internal/directive/diff.go` — wrapper над `env.Diff`.
- `internal/env/ignore.go` — список ignored keys.

**Acceptance**:
- Diff корректно показывает новые/изменённые/удалённые переменные.
- `PATH` обрабатывается через `_.path`, не через `export PATH=...`.
- `_*`, `OLDPWD`, `PWD` не трогаются.

**Effort**: 0.5 дня.

### T1.7 — Emit shell commands

**Что делаем**: для каждой `DiffOp` генерируем shell-команду через `shell.Adapter`.

**Поведение**:
- `Set` → `adapter.Export(key, adapter.Escape(value))`.
- `Unset` → `adapter.Unset(key)`.
- `PATH` — через `adapter.SetPath(dirs)`.

**Файлы**: используем существующий `internal/shell` — изменений не нужно.

**Acceptance**:
- `envee eval bash` в `examples/basic` выдаёт валидный bash script.
- `envee eval fish` выдаёт валидный fish script.
- Escape корректно работает для `it's`, `$VAR`, etc.

**Effort**: 0.5 дня (это в основном T1.1).

### T1.8 — Tests + golden fixtures

**Что делаем**: golden tests на каждый example.

**Файлы**:
- `internal/directive/directive_test.go` — unit tests.
- `internal/cli/testdata/basic.golden.sh` — expected output for `examples/basic`.
- `internal/cli/testdata/multi-profile-dev.golden.sh` — for `examples/multi-profile` with profile=dev.
- `internal/cli/testdata/multi-profile-prod.golden.sh` — for prod (with secrets stub).
- `internal/cli/testdata/monorepo-api.golden.sh` — for monorepo.

**Test runner**:
```go
func TestEvalGolden(t *testing.T) {
    cases := []struct{
        name, configDir, profile string
    }{
        {"basic", "../../examples/basic", ""},
        {"multi-profile-dev", "../../examples/multi-profile", "dev"},
        {"monorepo-api", "../../examples/monorepo/services/api", ""},
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            got := runEval(tc.configDir, tc.profile, "bash")
            golden.Assert(t, got, tc.name + ".golden.sh")
        })
    }
}
```

**Acceptance**:
- Все golden tests проходят.
- Secrets пример использует mock plugin (см. C).

**Effort**: 1.5 дня.

**Total A**: ~7 дней.

---

## B. `envee trust` с TUI

**Что это**: интерактивный flow, в котором user видит diff, решает доверять или нет, и подписывает запись (если хочет).

**Цель MVP-B**: `envee trust` в `examples/basic` показывает diff в pager-like формате, спрашивает Y/n/d/s, по Y — записывает trust-store entry.

### T2.1 — Canonical hash (already in trust store)

**Что делаем**: убедиться, что `trust.CanonicalHash` используется и в `envee eval` (для проверки trust), и в `envee trust` (для записи).

**Файлы**:
- `internal/trust/canonical.go` — вынести `CanonicalHash` из `store.go` в отдельный файл, добавить комментарии.

**Acceptance**: hash стабилен к форматированию (re-marshal).

**Effort**: 0.25 дня.

### T2.2 — Diff display

**Что делаем**: человекочитаемый показ изменений, которые внесёт trust (что будет loaded, какие plugins, какие secrets).

**Формат**:
```
Trust envee.toml at /Users/alice/work/myproj?

  Schema:     envee/v1
  Profile:    dev
  Env vars:   12 (3 redacted)
  PATH adds:  2
  Dotenv:     .env, .env.local (redacted)
  Scripts:    none
  Secrets:    1 source (op)

  Required:   DATABASE_URL, API_KEY
  Watches:    Cargo.toml, package.json

Security check:
  ✓ no bash scripts
  ✓ all secret sources installed
  ✓ no network calls in scripts
  ⚠ DEBUG: variable name suggests secret, but redact=false

  sha256:abc123def456...

Trust? [Y/n/d(iff)/s(how)/q(uit)]
```

**Файлы**:
- `internal/trust/diff.go` — `Summary(cfg, directives) string` — генерирует summary.
- `internal/trust/security.go` — `Check(cfg) []Warning` — static security checks.

**Acceptance**:
- Summary не падает на partial configs.
- Warnings корректно классифицированы (ERROR vs WARN).

**Effort**: 1 день.

### T2.3 — Interactive prompt (basic, no TUI)

**Что делаем**: читаем Y/n/d/s из stdin через `bufio.Scanner`.

**Поведение**:
- Y → grant trust.
- n → exit without changes.
- d → show full diff (raw `envee.toml` content).
- s → skip (например, user хочет `envee trust --secrets-only`).
- q → quit.
- default (Enter) → Y (если TTY) или Y (если `--yes`).

**Файлы**:
- `internal/trust/prompt.go` — `Prompt(question string, options PromptOptions) (Response, error)`.

**Acceptance**:
- `echo "Y\n" | envee trust` работает non-interactive.
- `envee trust --yes` пропускает prompt.
- EOF → error (не паника).

**Effort**: 0.5 дня.

### T2.4 — TUI mode (опционально, Phase 2)

**Что делаем**: rich TUI с `charmbracelet/bubbles` или `tview`:
- Side-by-side diff view.
- Live JSON-tree view config.
- Trust button.

**Файлы**:
- `internal/trust/tui.go` — TUI mode.
- Зависимость: `github.com/charmbracelet/bubbles` или `github.com/rivo/tview`.

**Acceptance** (если успеем):
- TUI работает в iTerm2, Terminal.app, GNOME Terminal.
- Fallback на text mode, если TUI fail.

**Effort**: 2 дня. **Можно отложить** в v0.2.x; для v0.1.x хватит T2.3.

### T2.5 — Trust gate in `envee eval`

**Что делаем**: при eval, проверяем `trust.Store.Status(file, hash)`. Если не Trusted → error E001 с подсказкой `envee trust`.

**Поведение**:
- Trusted → continue.
- Expired → error E001.
- Denied → error E010.
- Unknown → error E001.

**Файлы**:
- `internal/trust/check.go` — `CheckFile(path, hash) (Status, error)`.
- `internal/cli/eval.go` — wire trust check (T1.1 refactored).
- ~~`internal/cli/init.go` — env var `ENVEE_BYPASS_TRUST=1` для тестов.~~ Отменено:
  envee экспортирует переменные в шелл пользователя, поэтому один доверенный конфиг
  мог бы выставить `ENVEE_BYPASS_TRUST=1` и отключить проверку доверия для всех
  остальных каталогов сессии. Тесты вместо этого подменяют `XDG_DATA_HOME` и
  наполняют trust-store напрямую. Конфигам запрещено задавать любые `ENVEE_*`.

**Acceptance**:
- `envee eval` в untusted `examples/basic` → error E001 с hint.
- `envee trust && envee eval` → OK.
- `envee trust --remove && envee eval` → снова error.

**Effort**: 0.5 дня.

### T2.6 — Sign support (`--sign`)

**Что делаем**: при trust, опционально подписать запись ed25519 ключом.

**Файлы**:
- `internal/trust/sign.go` — используем `golang.org/x/crypto/ed25519`.
- Wire в `internal/cli/trust.go`.

**Acceptance**:
- `envee trust --sign --key ~/.ssh/id_ed25519` подписывает.
- Запись содержит поле `signature` с algorithm + key_id + value.

**Effort**: 0.5 дня.

**Total B**: ~3 дня (T2.1-T2.3, T2.5-T2.6; T2.4 опционально +2 дня).

---

## C. Plugin SDK + `envee-plugin-env`

**Что это**: реализация протокола ADR-0007. SDK = Go-пакет для авторов плагинов. `envee-plugin-env` = первый реальный плагин, читает `.env` файлы как секрет.

**Цель MVP-C**: `envee secret set DATABASE_PASSWORD=foo` сохраняет в OS keyring; `envee eval` подгружает через plugin.

### T3.1 — `pkg/plugin-sdk-go` (новый Go-пакет)

**Что делаем**: переиспользуемый SDK для plugin-авторов.

**Файлы**:
- `pkg/sdk-go/plugin.go` — `Run(Plugin)` main entry.
- `pkg/sdk-go/protocol.go` — message types (Request, Response, Error).
- `pkg/sdk-go/errors.go` — error codes.
- `pkg/sdk-go/README.md` — документация.

**API**:
```go
package main

import "github.com/baken667/envee/pkg/sdk-go/plugin"

func main() {
    plugin.Run(plugin.Plugin{
        Metadata: plugin.Metadata{
            Name: "my-plugin",
            Version: "0.1.0",
            Capabilities: []string{"secret"},
        },
        Resolve: func(req plugin.Request) (plugin.Response, error) {
            // ... user logic ...
            return plugin.Response{
                Status: "ok",
                Value: &plugin.Value{Type: "string", Value: "secret"},
            }, nil
        },
    })
}
```

**Acceptance**:
- SDK компилируется в отдельный Go-модуль.
- Plugin-автор может написать plugin в 30 строк.
- Протокол версии 1 (стабильный).

**Effort**: 1.5 дня.

### T3.2 — Wire plugin invocation в `internal/directive`

**Что делаем**: когда eval встречает `_.secret.X`, ищет plugin `envee-plugin-<source>` в PATH, вызывает, кеширует.

**Поведение**:
- `internal/plugin/registry.go` уже есть (discovery) — расширяем `Resolve()`.
- Новый `internal/secret/cache.go` — in-memory cache с TTL.
- `internal/directive/secret.go` — вызывает plugin, кладёт в env.

**Файлы**:
- `internal/secret/cache.go` — TTL cache.
- `internal/directive/secret.go` — orchestration.

**Acceptance**:
- `_.secret.DATABASE_PASSWORD = { source = "env", ref = "..." }` резолвится через `envee-plugin-env`.
- Cache hit на 2-й eval.
- Plugin error → error E004 с diag.

**Effort**: 1 день.

### T3.3 — `envee-plugin-env` (новый бинарь)

**Что делаем**: первый реальный плагин. Читает переменные из локального `.env`-стиля хранилища.

**Поведение**:
- `metadata` → возвращает `{name: "env", version: "0.1.0", capabilities: ["secret"]}`.
- `resolve` с spec `{ref: "DATABASE_PASSWORD"}` → читает из `$XDG_DATA_HOME/envee/secrets/env.json` (простой JSON-файл).
- `envee secret set KEY=VALUE` (CLI в envee) → пишет в `secrets/env.json`.

**Файлы**:
- `plugins/env/main.go` — plugin main.
- `plugins/env/go.mod` — отдельный Go-модуль (для plugin-авторов).
- `internal/cli/secret.go` — `envee secret set/unset/list` (новые subcommands).

**Acceptance**:
- `envee secret set DATABASE_PASSWORD=hunter2` → запись в `~/.local/share/envee/secrets/env.json`.
- `envee eval` в проекте с `_.secret.DATABASE_PASSWORD = { source = "env" }` → переменная `DATABASE_PASSWORD=hunter2`.
- `envee secret list` показывает все.

**Effort**: 1.5 дня.

### T3.4 — Plugin discovery + timeout

**Что делаем**: plugin discovery работает при первом eval, кешируется на 24 часа, fail-fast если plugin не найден.

**Acceptance**:
- Plugin lookup < 5ms.
- Отсутствующий plugin → error E009 с install hint.

**Effort**: 0.5 дня (часть T3.2).

### T3.5 — Plugin e2e test

**Что делаем**: тест, который:
1. Создаёт mock env-plugin.
2. Создаёт test `envee.toml` с `_.secret.X = { source = "env", ref = "X" }`.
3. Запускает `envee eval` end-to-end.
4. Проверяет, что `X` имеет ожидаемое значение.

**Файлы**:
- `internal/directive/secret_e2e_test.go`.

**Acceptance**: тест проходит, нет flakiness.

**Effort**: 0.5 дня.

**Total C**: ~5 дней.

---

## Интеграция: T1.1 + T2.5 + T3.2

После того как A, B, C готовы по отдельности, интегрируем:

1. **Eval flow** (T1.1 + T2.5):
   ```go
   func runEval(...) error {
       cfg, err := resolver.LoadAll(...)
       if err != nil { return err }
       
       // Trust gate
       if !bypassTrust {
           st, _ := trust.CheckFile(cfg.Path, cfg.FileHash)
           if st != trust.Trusted { return errs.Trust(cfg.Path, cfg.FileHash) }
       }
       
       // Apply directives
       env, err := directive.Apply(ctx, cfg, registry)
       if err != nil { return err }
       
       // Diff + emit
       diff := osEnv.Diff(env)
       out := shell.FormatDiff(adapter, diff)
       fmt.Print(out)
       return nil
   }
   ```

2. **Plugin wiring** (T3.2 в T1.1):
   ```go
   func runEval(...) error {
       // ... cfg loaded ...
       
       reg, err := plugin.Discover(ctx)
       if err != nil { log.Warn("plugin discovery: %v", err) }
       
       env, err := directive.Apply(ctx, cfg, reg)  // reg passes through
       if err != nil { return err }
       
       // ... emit ...
   }
   ```

3. **Wiring `examples/secrets`**:
   - Добавить test plugin в `internal/directive/testdata/mock-plugins/`.
   - Запустить e2e на `examples/secrets` → проверить, что DATABASE_PASSWORD подгружается.

**Effort**: 1 день.

---

## Milestone'ы и релизная стратегия

### Milestone 1: v0.1.0-alpha (день ~7)

**Включает**:
- T1.1, T1.2, T1.3, T1.4, T1.5, T1.6, T1.7 (eval end-to-end).
- T1.8 (golden tests на basic, multi-profile, monorepo).
- Без trust gate, без plugins.

**Demo**:
```bash
$ cd examples/basic
$ envee eval bash
export SERVICE_NAME='myapp';
export DATABASE_URL='postgres://localhost:5432/mydb';
...
export PATH='/.../examples/basic/bin:/usr/local/bin:...';
```

**Tag**: `v0.1.0-alpha` (pre-release, no Homebrew push).

### Milestone 2: v0.1.0-beta (день ~10)

**Включает**:
- B (T2.1, T2.2, T2.3, T2.5, T2.6 — без TUI).
- Trust gate интегрирован.
- Примеры secrets остаются stub.

**Demo**:
```bash
$ cd examples/basic
$ envee trust
[envee] Trust envee.toml at /Users/.../basic? [Y/n/d(iff)/s/q] Y
Trusted. sha256:abc...
$ envee eval bash
...
$ cd ..  # change dir
$ cd examples/basic  # re-enter
$ echo $SERVICE_NAME  # works
```

**Tag**: `v0.1.0-beta`.

### Milestone 3: v0.1.0 (день ~14)

**Включает**:
- C (T3.1, T3.2, T3.3, T3.5).
- Полный plugin SDK.
- `envee-plugin-env` working.
- `envee secret set/unset/list`.
- Integration tests.
- README updates.
- Homebrew auto-publish (GoReleaser → tap PR).

**Demo**:
```bash
$ envee secret set DATABASE_PASSWORD=hunter2
$ cd examples/secrets
$ envee trust
$ envee eval bash
...
export DATABASE_PASSWORD='hunter2';
```

**Tag**: `v0.1.0` → автоматический Homebrew PR → review → merge → users get `brew install baken667/tap/envee`.

### Milestone 4: v0.2.0 (TUI + benchmarks, день ~17)

**Включает**:
- T2.4 (TUI mode).
- Perf benchmarks vs direnv.
- Documentation site (GitHub Pages).
- Promo на HN, r/rust, r/golang.

---

## Риски

| Риск | Вероятность | Импакт | Митигация |
|---|---|---|---|
| BurntSushi/toml edge cases в template values | Medium | Medium | extensive golden tests; document known issues |
| Race conditions в plugin discovery | Low | Medium | mutex в Registry; cache TTL |
| Secret values leak в logs | Medium | High | redactingHandler (DONE) + audit logging + security review |
| `envee trust` flow confusing → users skip review | Medium | High | show diff by default; dry-run mode; security checklist в README |
| TUI breaks in some terminals | High | Low | T2.4 optional; text mode по умолчанию |
| WASM sandbox escape (T6.1 в future) | Low | High | T2.2 security.go статически проверяет `.wasm` files; Phase 3 review |
| Homebrew auto-merge бот плохо тестируется | Low | Medium | dry-run on tag; manual review первой версии |

---

## Что НЕ входит в эти 3 этапа (deferred)

- WASM `_.script` (Phase 3 per ADR-0006).
- Daemon `enveed` IPC (Phase 3 per ADR-0008).
- OS keyring cache (Phase 3 per ADR-0009) — пока in-memory cache.
- nushell, pwsh, elvish hooks (Phase 2 per ADR-0012).
- apt/rpm/snap packages (Phase 2 per ADR-0014).
- `envee import .envrc` migration tool (Phase 2 per ADR-0013).
- TUI mode (T2.4 — optional).
- Vault, AWS, 1Password plugins (Phase 3 — после `envee-plugin-env`).

---

## Acceptance criteria для всего этапа (A+B+C)

**Definition of Done**:
- [ ] `envee eval bash` в `examples/basic` выдаёт валидный bash с правильными exports.
- [ ] `envee eval bash` в `examples/multi-profile` с `--profile=prod` подгружает prod-overlay.
- [ ] `envee eval bash` в `examples/monorepo/services/api` мерджит root + service.
- [ ] `envee trust` интерактивно работает в TTY и non-TTY.
- [ ] `envee trust --sign` подписывает ed25519.
- [ ] `envee eval` без trust → error E001.
- [ ] `envee secret set X=Y` сохраняет.
- [ ] `envee eval` в `examples/secrets` подгружает X через `envee-plugin-env`.
- [ ] Golden tests проходят.
- [ ] `go test -race ./...` зелёный.
- [ ] `goreleaser check` зелёный.
- [ ] README обновлён с примерами.
- [ ] v0.1.0 tagged → GoReleaser успешно собрал → tap PR создан.
- [ ] `brew install baken667/tap/envee` ставит и запускает `envee --version`.

**Estimated total effort**: 13-16 дней (~2.5-3 недели) для всех трёх этапов с proper testing.

---

## Следующие шаги

Я предлагаю начать с **A (T1.1) → T1.2 → T1.3** (eval end-to-end без trust/plugins). Это даст быстрый вин — реальный `envee eval` за ~2 дня. Параллельно можно начать B (T2.1-T2.3) в фоне.

Затем:
- T1.4-T1.5 (profile + templates) — 2 дня.
- T2.5 (trust gate) — 0.5 дня.
- T3 (plugin SDK + env) — 5 дней.
- T1.8 (golden tests) — 1 день.
- Release — 1 день.

Итого: ~12 дней до v0.1.0.

Скажи, если согласен с планом — начну с A (T1.1) немедленно. Или скорректируй приоритеты / scope.
