# Envee — альтернатива direnv: исследование и план реализации

> Документ с анализом существующих решений и планом собственной реализации.
> Исходники клонированы локально в `./_research/{direnv,quickenv,mise}` и изучены.

## 1. Что вообще существует

| Проект | Язык | Суть | Главный trade-off |
|---|---|---|---|
| [direnv](https://github.com/direnv/direnv) | Go | Классика. `.envrc` = bash-скрипт, выполняется в subshell, diff экспортируется через `eval` в hook | Скрипт = bash. Недетерминированно, медленно если `.envrc` тяжёлый |
| [mise `[env]`](https://mise.jdx.dev/environments/) | Rust | Декларативный TOML. Объединяет env + tool mgmt + tasks | Монолит (336K LOC), не отдельный инструмент, конфликтует с direnv |
| [quickenv](https://codeberg.org/untitaker/quickenv) | Rust | `.envrc`-совместим, но **без shell hook** — кеш + `quickenv reload` руками | Не загружает env автоматически при `cd` |
| [shadowenv](https://github.com/shopify/shadowenv) | Rust | `.shadowenv.d/*.lisp` — Scheme-подобный DSL | Декларативный, sandboxed, но экзотика |
| [autoenv](https://github.com/hyperupcall/autoenv) | Bash | Один файл. `.env` + `.env.leave`, source в текущей оболочке | Нет unload-механизма, `cd` overrides, мёртвый по сути |
| [zsh-autoenv](https://github.com/Tarrasch/zsh-autoenv) | Zsh | `.autoenv.zsh` + `.autoenv_leave.zsh`, встроенный stash PATH | Только zsh, нет кроссшелла |
| [envrc (emacs)](https://github.com/purcell/envrc) | Emacs Lisp | Пакет для Emacs — интегрирует direnv в буфер | Не самостоятельный |
| [devenv](https://devenv.sh) | Nix | Reproducible envs через Nix flakes + direnv внутри | Требует Nix |
| [asdf-direnv](https://github.com/asdf-community/asdf-direnv) | Bash lib | Мост между asdf и direnv | Не самостоятельный |

Подробно изучены исходники: **direnv** (5.5K LOC Go), **quickenv** (1K LOC Rust), **mise** (336K LOC Rust).

## 2. Как устроен direnv внутри (релевантные куски кода)

`internal/cmd/rc.go` — `.envrc` lifecycle:

```go
// Каждый раз при cd:
//  1. findEnvUp — ищет .envrc/.env вверх по дереву
//  2. RC.Allowed() — проверяет ~/.config/direnv/allow/<sha256(absolute+content)>
//  3. RC.Load(previousEnv):
//       cmd = exec.CommandContext(ctx, "bash", "-c", arg)
//       arg = `eval "$(direnv stdlib)" && __main__ source_env <escaped path>`
//       cmd.Env = newEnv.ToGoEnv()
//       cmd.Stdin = os.Stdin  // <-- источник #1 проблем
//       out, _ := cmd.Output()
//       newEnv2 := LoadEnvJSON(out)
//  4. previousEnv.Diff(newEnv).ToShell(shell) → "export X=Y; unset Z;..."
//  5. shell hook делает eval этих команд
```

`internal/cmd/env_diff.go` — сам diff:

```go
var IgnoredKeys = map[string]bool{
    "COMP_WORDBREAKS": true, // избегает сегфолтов в bash
    "PS1": true,             // PS1 не должен экспортироваться
    "OLDPWD": true, "PWD": true, "SHELL": true, "_": true,
    // ...
    "DIRENV_*": skip,
    "BASH_FUNC_*": true,
    "__fish*": true,
}
```

Алгоритм diff: `Prev` = переменные, которые были и либо изменились, либо исчезли; `Next` = те, что появились или изменились. Затем `ToShell(shell)` генерирует `export …;` и `unset …;` через `BashEscape` (свой правильный escape, не shellwords).

Shell hook (bash, `shell_bash.go`):

```bash
_direnv_hook() {
  local previous_exit_status=$?
  vars="$("{{.SelfPath}}" export bash)"
  trap -- '' SIGINT
  eval "$vars"
  trap - SIGINT
  return $previous_exit_status
}
# цепляется к PROMPT_COMMAND
```

`internal/cmd/file_times.go` — `FileTimes` хранит mtime всех watched-файлов, чтобы перезагружать только при изменении.

`pkg/dotenv/parse.go` — самописный парсер `.env` на regex. Поддерживает `KEY=val`, `export KEY=val`, кавычки, многострочные значения.

## 3. Сборник минусов / пробелов (то, что исправляем)

### 3.1 Безопасность
- **Bash внутри `.envrc` — это RCE**. `direnv allow` запускает произвольный bash. Любой `git clone` может принести `.envrc` со вредоносным кодом. Лучшее, что есть — allow-list по sha256 + явный `direnv allow`. Нет статического анализа, нет sandbox.
- **`os.Stdin` передаётся в bash по умолчанию** — `.envrc` может случайно подвесить shell, читая stdin, или прочитать пароль из `read -s`. Лечится `disable_stdin = true`, но по умолчанию выключено.
- **Nix users пишут `use nix` → блокирующий вызов `nix-shell`** на каждом prompt. См. direnv best practices: «do not block».
- **deny/allow файлы в `~/.config/direnv/{allow,deny}/<hash>`** — пути предсказуемы, `~/.config/direnv/allow` иногда случайно синкается в облако (iCloud/Dropbox/syncthing) → утечка allow-state.

### 3.2 Производительность
- **Shell hook выполняется на каждый `PROMPT_COMMAND`** — даже когда `.envrc` не изменился. Direnv делает `FileTimes.Check()` и short-circuit, но всё равно fork+exec процесса direnv на каждый prompt (~5–15ms).
- **`direnv hook zsh` тоже спавнит процесс при старте shell** (~10–20ms). Люди кешируют `direnv hook zsh > $XDG_CACHE_HOME/direnv-hook.zsh`.
- **Bash startup при каждой перезагрузке `.envrc`**: `bash -c "..."` — это ~5–10ms без нагрузки, но stdlib грузится в bash каждый раз.
- **Нет incremental watch**: `direnv watch` есть, но базовый механизм — `mtime` polling. На больших репах (тысячи watched файлов) тормозит.
- **No prebuilt cross-compile для Windows ARM** — direnv заявлен кроссплатформенный, но `bash` под капотом всё равно нужен.

### 3.3 UX
- **`direnv allow` — два шага** (отредактировал → allow → только тогда работает). Раздражает на старте.
- **Шум при ошибке**: «direnv: error .envrc is blocked» + diff при изменении файла + diff при reload. Нет quiet mode.
- **Плохое поведение `cd` вглубь**: если в подпапке нет своего `.envrc`, переменные родителя разгружаются (issue #84 «direnv shouldn't unload when no .envrc below»). Нужно явно `source_up` или `dotenv_if_exists`.
- **Нет undo/redo, нет dry-run** (`what would change if I cd here?`).
- **Нет машиночитаемого вывода** для интеграций кроме `direnv export json` (а у того JSON нестабильный, поля `p`/`n`).
- **Нет `envdiff`** (посмотреть, что накопилось, и откатить вручную). Команда `direnv status` показывает состояние, но не diff в текущий shell.
- **Conflict with mise/direnv**: mise явно пишет «using direnv with mise is unsupported».
- **TUI-less статус**: при работе в tmux/IDE интеграции (VSCode, JetBrains) подхватывают direnv, но IDE не видит, что direnv перезагрузил env, пока сам не вызовет `direnv reload`.

### 3.4 Архитектурные
- **Всё в одном бинаре на Go**, что хорошо, но:
  - 1552 строки `stdlib.sh` внутри репо — нельзя обновить stdlib независимо от бинаря.
  - **Нет плагинов**: extensions живут в `~/.config/direnv/lib/*.sh` и пишутся на bash. Цикл обратной связи медленный.
- **Per-shell `shell_*.go`** — для каждого нового shell (Nushell, Oil, Xonsh) нужно писать свой адаптер.
- **`.envrc` = bash script** — это фича (мощно) и баг (небезопасно, недетерминированно, непортируемо). Нет first-class альтернативы кроме «написать bash».
- **No JSON-Schema / typed env**: нельзя валидировать `DATABASE_URL` против типа URL, нельзя требовать `required = true` для критичных переменных (mise это добавил, но это фича mise, не direnv).
- **Нет профилей/слоёв** (dev/test/stage/prod) — `MISE_ENV=dev` у mise это закрывает, но в чистом direnv только `source_env .envrc.dev` руками.

### 3.5 quickenv — что он исправляет, а что ломает
- ✅ Кеш результата → не нужно перезапускать bash при каждом prompt.
- ✅ Не нужен shell hook → меньше старт shell.
- ✅ Нет `direnv allow` boilerplate — каждое `quickenv reload` заново валидирует.
- ❌ **Никакой автоматической загрузки** при `cd`. Пользователь должен сам ввести `quickenv reload && eval "$(quickenv vars)"`. Это убивает главную фичу direnv.
- ❌ Нет diff — кешируется сразу итоговое состояние env, не дифф. Поэтому нельзя сделать `direnv unload` корректно (точнее, можно, но через полный revert, а у quickenv revert — это вычесть текущий PATH).
- ❌ Полностью Unix-only (`std::os::unix::*`).

### 3.6 shadowenv — что он делает хорошо
- ✅ Sandbox: лимит 100ms на выполнение `.shadowenv.d/*.lisp` → нельзя случайно повесить shell.
- ✅ Декларативный (не императивный bash).
- ✅ Trust + nested через symlink `.shadowenv.d/parent`.
- ❌ Scheme-подобный DSL — экзотика, незнакомо большинству.
- ❌ Экосистема мертва (последний активный коммит 2018–2019, archived).

### 3.7 mise — что он добавил
- ✅ Декларативный TOML (вместо bash).
- ✅ `required = true`, `redact = true`, `_.file`/json/yaml, `_.path` массив, `_.source` для source-скриптов.
- ✅ `MISE_ENV=dev|prod` — профили.
- ✅ Шаблоны `{{config_root}}`, `{{env.X}}`, `{{ tools.node.version }}`.
- ❌ Конфликтует с direnv (явно unsupported).
- ❌ Монолит: 336K LOC, тащит менеджер версий + task runner.
- ❌ Свой собственный watch-механизм, загрузка идёт через `mise env --json | jq -r 'to_entries[] | "export \(.key)=\(.value)"'`.

## 4. Envee: цели и принципы

Из пробелов формулируем «Энви» (env + ee):

**Цель**: быстрая, безопасная, декларативная замена direnv с first-class поддержкой профилей, типизированных переменных и не-инвазивной интеграцией в shell.

**Принципы**:
1. **Single static binary**, ноль рантайм-зависимостей.
2. **Декларативный конфиг** (TOML) с **optional script block** (WASM sandbox, не bash) — пользователь явно выбирает уровень доверия.
3. **Trust по содержимому, не только по hash файла**: re-approval при изменении хотя бы одного байта, плюс optional проверка подписи.
4. **Hooks только там, где надо**: prompt hook — лёгкий, не делает `export` сам, только проверяет «не изменился ли конфиг?». Если изменился — запускается reload. Иначе — no-op.
5. **Watch через inotify/FSEvents**, не mtime polling.
6. **Plug-in для секретов**: интеграция с `op`, `1Password`, `vault`, `age`, `sops`, без копирования секретов в `.envrc`.
7. **Машиночитаемый вывод** по умолчанию — `--json`, стабильная схема v1+.
8. **Per-shell адаптеры** — отдельные маленькие shell-скрипты (50-100 строк), генерируются из общего шаблона.

**Имя**: `envee` (env + ee) — короткое, вводится 5 букв, не конфликтует с существующими пакетами.

## 5. Стек: Go или Rust?

| Критерий | Go | Rust |
|---|---|---|
| Single static binary | ✅ cgo-free | ✅ |
| Размер бинаря | ~8–12 MB | ~3–5 MB |
| Startup | ~5 ms | ~2–3 ms |
| Кросс-компиляция | ✅ отличная | ✅ отличная |
| FFI к shell, libc | просто через `os/exec` | тоже |
| Watch (inotify/FSEvents) | `fsnotify` (mature) | `notify` (mature) |
| TOML парсер | `BurntSushi/toml` | `toml-rs`, `toml_edit` |
| Экосистема секретов | сильная | сильная |
| Recruitability | Go devs больше | Rust devs меньше |
| Sandboxing для скриптов | через wasmtime-go | через wasmtime-rust |

**Рекомендация: Go**, по причинам:

1. **Direnv — на Go**, и это reference. Половина решений уже проверена (`exec.CommandContext`, `fsnotify`, `toml`). Не надо изобретать.
2. **В 1.5–2 раза быстрее писать MVP**. План ниже оценивается в 4–6 недель solo на Go против 8–12 на Rust.
3. **WASM-sandbox** — это всё равно через `wasmtime-go` биндинги, одинаково.
4. **Go-кодовая база direnv = 5.5K LOC** — мы хотим быть **конкурентно меньше** (Go хорош для компактности).
5. Если позже нужно выжать перф — переписать на Rust, имея reference impl.

Компромисс: **внутренний VM-движок** (для безопасных скриптов) напишем на **WASM** (Wazero или Wasmtime). Это переносимо между Go и Rust.

## 6. Архитектура

```
                  ┌─────────────────┐
                  │  shell hook.sh  │  (50 строк на shell, автогенерация)
                  │  trap PROMPT    │
                  └────────┬────────┘
                           │ `envee eval $SHELL`
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                       ENVEED DAEMON (опц.)                   │
│  ┌─────────────┐  ┌────────────┐  ┌────────────┐             │
│  │ inotify     │  │ fingerprint│  │ policy     │             │
│  │ watcher     │  │ + hash     │  │ engine     │             │
│  └──────┬──────┘  └─────┬──────┘  └─────┬──────┘             │
│         │               │               │                    │
│  ┌──────▼───────────────▼───────────────▼──────────────┐     │
│  │  config resolver: TOML + env.* + profile overlay   │     │
│  └──────────────────────────┬──────────────────────────┘     │
│                             │                                │
│  ┌──────────────────────────▼──────────────────────────┐     │
│  │  env layer merge: dotenv + TOML + secrets + script  │     │
│  └──────────────────────────┬──────────────────────────┘     │
│                             │                                │
│  ┌──────────────────────────▼──────────────────────────┐     │
│  │  shell adapter: bash|zsh|fish|nushell|pwsh|elvish   │     │
│  │  Export / Unset / Set commands                       │     │
│  └─────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

### 6.1 Конфиг-файлы и приоритет

По аналогии с mise (от высшего к низшему):
- `envee.local.toml` (гитignored, персональные override)
- `envee.toml` (коммитится)
- `<имя>.envee.toml` (профили)
- `envee.d/*.toml` (модули, грузятся алфавитно)
- `~/.config/envee/config.toml` (глобальные дефолты)

Найдено вверх по дереву от CWD, **мерджатся**, child > parent, local > git-tracked.

### 6.2 Формат `.envee.toml` (или `envee.toml`)

```toml
# schema: https://envee.dev/schemas/envee-v1.json
schema = "envee/v1"

# Профиль по умолчанию; можно переопределить ENVEE_PROFILE=dev
profile = "dev"

[env]
# Простые скаляры
DATABASE_URL = "postgres://localhost/mydb"
PORT = 5432
DEBUG = true

# Шаблоны
LOG_PATH = "{{config_root}}/logs/{{profile}}.log"

# Required — падать, если не задана внешним слоем
API_KEY = { value = "default-dev-key", required = false, redact = true }

# Загрузить .env из файла
_.file = [".env", { path = ".env.local", redact = true }]

# Поддержать JSON, YAML, TOML
# _.file = { path = ".env.json", format = "json" }

# Добавить в PATH (не теряя старые)
_.path = ["./node_modules/.bin", "{{config_root}}/bin"]

# Source безопасного WASM-скрипта (см. 6.4)
_.script = "./scripts/env.wasm"

# Плагин секретов
_.secret.AWS_CREDS = { source = "aws", profile = "dev" }
_.secret.GITHUB_TOKEN = { source = "gh", field = "token" }

[profiles.dev]
DATABASE_URL = "postgres://localhost/mydb_dev"

[profiles.prod]
DATABASE_URL = "postgres://prod.example.com/mydb"
required = ["API_KEY", "DATABASE_URL"]   # в этом профиле обязательны

[scripts]
# pre/post hooks при reload
pre_reload = "echo 'loading dev env'"
```

### 6.3 Декларативные слои env

`envee resolve` (новая команда) — без shell hook'а выводит итоговый env, объединяя:
1. `os.Environ()` (текущий shell)
2. dotenv-файлы
3. JSON/YAML/TOML файлы
4. TOML `[env]`
5. Profile-merge
6. Plugin secrets
7. Optional WASM script
8. PATH layers

`envee eval $SHELL` — то же самое, но выводит в формате `export ...;` для eval'а.

`envee diff $SHELL` — только дельта от текущего `os.Environ()`, не весь env.

### 6.4 Script layer: WASM (опционально, не по умолчанию)

Для power-users, которым нужна логика (например, derive JWT, compute timestamp), есть возможность написать **WASM-модуль** на любом языке с WASM-target (Rust, Go, AssemblyScript, JS→WASM):

```rust
// scripts/env.rs → wasm32-wasi target
#[export_name = "envee_set"]
pub fn set(req_ptr: *const u8, req_len: usize, out_ptr: *mut u8, out_cap: usize) -> i32 {
    // читает JSON {"env": {...}, "cwd": "..."} через host-import
    // пишет {"set": {"FOO": "bar"}, "unset": ["BAZ"]}
}
```

Envee делает **host-imports** для: `envee.getenv(name) -> string`, `envee.read_file(path) -> bytes`, `envee.exec(cmd) -> string`. Квота: 100ms CPU, 64MB памяти, нет сетевых host-imports (по умолчанию).

**Почему не bash**: bash в `.envrc` — это RCE. WASM sandbox — это capability-based, no escape. User пишет `envee.toml` декларативно для 95% случаев; WASM нужен только для сложной логики.

### 6.5 Trust model

```
                  ┌──────────────────────────────┐
                  │   envee.toml в репозитории   │
                  │   (не подписан)              │
                  └────────────┬─────────────────┘
                               │ git clone → untrusted
                               ▼
                  ┌──────────────────────────────┐
                  │   envee check                 │
                  │   compute SHA-256             │
                  │   добавить в trust list       │
                  └────────────┬─────────────────┘
                               │ envee trust <path>
                               ▼
        ┌──────────────────────────────────────────┐
        │   $XDG_CONFIG_HOME/envee/trust/         │
        │   <sha256(content+path)>.json           │
        │   {                                     │
        │     "hash": "abc...",                   │
        │     "trusted_at": "2026-09-08T...",     │
        │     "trusted_by": "user",               │
        │     "signature": "ed25519:..." (opt)    │
        │   }                                     │
        └──────────────────────────────────────────┘
```

`envee trust --sign <key>` — подписать trust-file. Полезно для shared dev environments (команда, CI).

`envee check` — статический анализ TOML: проверка, что нет `_.script`, ведущего наружу, что все `_.secret.*` источники разрешены, что нет `_.path` за пределы `config_root`.

### 6.6 Shell hook (генерируется, 50 строк на shell)

Пример для bash:

```bash
_envee_hook() {
  local previous_exit_status=$?
  local out
  out="$("$ENVEE_BIN" eval bash 2>/dev/null)"; local rc=$?
  if [[ $rc -eq 0 && -n "$out" ]]; then
    eval "$out"
  elif [[ $rc -ne 0 ]]; then
    "$ENVEE_BIN" status || true
  fi
  return $previous_exit_status
}
case ";${PROMPT_COMMAND[*]:-};" in
  *";_envee_hook;"*) ;;
  *) PROMPT_COMMAND="_envee_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
```

`envee eval bash` внутри:
1. `stat` mtime `envee.toml` (через inotify в daemon — O(1))
2. Если mtime не менялся и `envee daemon` уже знает актуальный env — выводит cached diff → ~0.5ms.
3. Если изменился или daemon не запущен — пересчёт, вывод shell-команд.

### 6.7 Daemon (опционально, не блокирует MVP)

`enveed` — фон, следит за inotify-событиями на всех envee.toml'ах в home dir, прогревает кеш для текущего cwd. Запускается через `envee daemon start` или автоматически при первом `envee eval` (через UNIX socket).

Без daemon: каждый `envee eval` — это fork+exec ~5ms. С daemon: ~0.5ms.

## 7. MVP (фаза 1, ~4–6 недель)

**Цель MVP**: feature-parity с direnv, но декларативно, без bash, с профилями, с secrets-плагином (хотя бы одним).

**Скоуп**:
- [x] `envee.toml` парсер (TOML, через BurntSushi/toml).
- [x] `envee resolve` — вывод итогового env (text + JSON).
- [x] `envee eval <shell>` — shell-specific export/unset.
- [x] `envee trust`, `envee deny`, `envee status`.
- [x] Shell hooks для bash, zsh, fish.
- [x] Профили (`[profiles.dev]`, `ENVEE_PROFILE=dev`).
- [x] Шаблоны `{{config_root}}`, `{{env.X}}`, `{{profile}}`.
- [x] `_.file` для `.env` (dotenv формат), `_.path` для PATH.
- [x] `required = true` валидация.
- [x] `redact = true` для `envee status --show-secret` (тогда виден, иначе маскируется).
- [x] `envee diff` — текущая дельта vs новый resolved env.
- [x] mtime-based fast path (как у direnv).
- [x] Тесты: golden tests на shell-exports, e2e на fixtures (5–10 .envee.toml).
- [x] Homebrew formula, `go install`, deb/rpm/scoop формулы.
- [x] README, man pages, schema-дока.

**Out of scope MVP**:
- WASM script layer.
- Daemon (inotify).
- Секреты-плагины (1Password, AWS, vault, age, sops).
- Shell hooks для nu/pwsh/elvish (только bash/zsh/fish).
- `envee exec`, `envee watch`.
- Cross-arch Windows native (только WSL).

## 8. Фаза 2 — perf и UX (после MVP, 4–6 недель)

- [x] `enveed` daemon + UNIX socket.
- [x] inotify/FSEvents watcher.
- [x] `envee exec` — выполнить команду с resolved env без hook'а (как `direnv exec`).
- [x] `envee watch <path>` — добавить path в watch list.
- [x] `envee check` — статический анализ TOML (security linter).
- [x] `envee completions <shell>` — генерящиеся.
- [x] Nushell, PowerShell, Elvish hooks.
- [x] `envee trust --sign` / `--verify` (ed25519).
- [x] Optional: TUI (`envee ui`) — просмотр активного env, профилей, what-if.

## 9. Фаза 3 — секреты и плагины (после фазы 2, 6–8 недель)

- [x] Plugin SDK: `envee plugin new`, `envee plugin install`, `envee plugin list`.
- [x] Встроенные плагины секретов: `1password`, `aws-sm`, `age`, `sops`, `vault`, `bitwarden`.
- [x] `_.secret.<NAME> = { source = "op", ref = "op://Dev/Database/password" }`.
- [x] Оффлайн-first: секреты кешируются в OS keychain (через `zalando/go-keyring`), TTL=15min.
- [x] WASM script layer (Wazero embedding).
- [x] `envee run <task>` (минимальный task runner, опционально).
- [x] `envee export vscode` / `envee export jetbrains` — форматы для IDE.

## 10. Структура репозитория

```
envee/
├── cmd/envee/main.go           # CLI entrypoint (~150 LOC)
├── internal/
│   ├── config/                 # TOML schema, merge, profiles, templates
│   ├── env/                    # env merge, diff, render
│   ├── secret/                 # plugin interface + built-in providers
│   ├── shell/                  # bash/zsh/fish/nu/pwsh adapters
│   ├── trust/                  # trust store, sign/verify
│   ├── watch/                  # inotify/FSEvents wrapper
│   ├── resolver/               # orchestration: find files, build env
│   └── daemon/                 # enveed (socket, IPC)
├── pkg/                        # публичные библиотеки для плагинов
│   └── pluginapi/
├── plugins/                    # встроенные secret-providers
│   ├── op/                     # 1Password CLI wrapper
│   ├── aws/                    # AWS SSO/SM
│   ├── age/
│   ├── sops/
│   └── vault/
├── stdlib/
│   ├── bash/init.sh            # 50 LOC per shell
│   ├── zsh/init.zsh
│   └── fish/init.fish
├── docs/
│   ├── adr/                    # Architecture Decision Records
│   ├── schema/envee-v1.json
│   └── examples/
├── testdata/
│   ├── fixtures/*.envee.toml   # golden tests
│   └── integration/
├── go.mod
├── go.sum
├── Makefile
├── README.md
├── PLAN.md                     # <-- этот файл
└── LICENSE (MIT или Apache-2.0)
```

## 11. Ключевые технические решения (ADR-список)

| # | Решение | Обоснование | Альтернативы |
|---|---|---|---|
| ADR-001 | Go 1.24+ | См. §5 | Rust 2024 edition |
| ADR-002 | TOML v1.0 | Schemable, мощнее dotenv, проще YAML | YAML, JSON, HCL |
| ADR-003 | `envee.toml` (имя), `envee.local.toml` (gitignore) | Чисто, коротко, не конфликтует с `.env*` | `.envoir`, `.envrc` (занято direnv) |
| ADR-004 | Конфиг-файлы ищутся вверх от CWD, мерджатся | Понятная иерархия | только cwd, или только project root |
| ADR-005 | Trust по sha256 + path + signature opt | Совместимо с direnv-mental model, плюс защита от drift | TOFU на основе path, GPG-только |
| ADR-006 | `eval` per shell, генератор hooks | Минимум shell-кода, легко тестировать | Один большой POSIX-sh hook |
| ADR-007 | Default: declarative TOML. Opt-in: WASM script. **Нет bash.** | Безопасность | bash с sandbox (clod), Lua с sandbox |
| ADR-008 | Daemon опционален, через UNIX socket | 80% user'ов не нужен, но когда нужен — критичен | Всегда daemon, всегда без daemon |
| ADR-009 | Plugin SDK: Go plugins (gRPC) или просто exec `envee-plugin-X`? | Exec — проще, безопасно, кросс-компилируется | HashiCorp go-plugin (gRPC) |
| ADR-010 | Лицензия: MIT | Совместимо с direnv (MIT), быстрая адаптация | Apache-2.0 |

## 12. Риски

- **`PROMPT_COMMAND` performance** — даже с нашим быстрым путём, hook добавляет минимум 1 fork+exec. Решение: in-process hook через shell builtin (zsh `zsh_evaluate_plugin`).
- **Race condition между trust и reload** — если файл изменился между trust и eval, надо сразу revoke. Решение: hash trust-записи проверяется при каждом load.
- **Sync конфликт с iCloud/Dropbox** для `~/.config/envee/`. Решение: явный флаг `--no-trust-store`, использование OS keyring для trust-entries.
- **WASM stdlib большой** (~1.5 MB на Wazero). Решение: optional `envee-wasm` feature, без него работает.
- **Сложность миграции** — у user'ов уже есть `.envrc` файлы. Решение: `envee import .envrc` — конвертирует bash-логику в декларативный TOML (лучшее, что можно автоматизировать) + WASM-блок.

## 13. Метрики успеха

- **Latency `envee eval` cold-start**: < 10ms (без daemon, без WASM).
- **Latency `envee eval` warm**: < 1ms (с daemon).
- **Latency shell startup** (`eval "$(envee init bash)"` cached): < 5ms.
- **Memory**: < 20 MB resident для daemon.
- **Binary size**: < 12 MB.
- **Test coverage**: > 85% для internal/, golden tests на все 5 shells.
- **Cross-compile targets**: linux/amd64, linux/arm64, linux/armv7, darwin/amd64, darwin/arm64, freebsd/amd64, windows/amd64 (через WSL, marked experimental).
- **Первые 100 звёзд на GitHub за 2 месяца** (PR в Hacker News, r/rust, r/golang, lobste.rs).

## 14. Что я бы начал делать прямо сейчас

1. **`go mod init github.com/baken667/envee`**, базовый CLI через `cobra` или `ffcli`.
2. **`internal/config`** — TOML schema, merge-логика, profile resolution. ~400 LOC.
3. **`internal/shell`** — bash/zsh/fish Export/Unset. ~200 LOC.
4. **`internal/env`** — Diff, render, redact. ~200 LOC.
5. **`cmd/envee/main.go`** — subcommands resolve/eval/trust/status/init. ~300 LOC.
6. **Tests + golden fixtures** — 4–6 .envee.toml с разными сценариями (простой, с профилями, с шаблонами, с secrets-stub, с PATH).
7. **CI на GitHub Actions** (linux/darwin, go test, golangci-lint).
8. **README** с quick start + сравнение с direnv/mise.
9. **Bench** `envee eval` vs `direnv export` — must be faster on cold path, equal on warm.

Оценочно MVP: **3–4 недели** на кодинг, **1 неделя** на полировку + доки + первый релиз.

---

## Приложение A. Полезные ссылки

- direnv best practices: <https://dev.to/allenap/some-direnv-best-practices-actually-just-one-4864>
- mise environments: <https://mise.jdx.dev/environments/>
- shadowenv (Shopify): <https://github.com/shopify/shadowenv>
- quickenv (Codeberg): <https://codeberg.org/untitaker/quickenv>
- `inotify` из Go: <https://github.com/fsnotify/fsnotify>
- TOML schema spec: <https://toml.io/en/v1.0>
- WASM host в Go: <https://github.com/tetratelabs/wazero>

## Приложение B. Где какие файлы в изученных исходниках

```
direnv/                        # Go, 5.5K LOC
├── internal/cmd/rc.go         # RC struct, Allow/Deny, Load (subshell)
├── internal/cmd/env.go        # Env type, GetEnv, ToShell
├── internal/cmd/env_diff.go   # EnvDiff, IgnoredKeys, ToShell
├── internal/cmd/cmd_export.go # exportCommand — сердце direnv
├── internal/cmd/file_times.go # mtime-based change detection
├── internal/cmd/cmd_watch.go  # watch list management
├── internal/cmd/cmd_dotenv.go # .env parser entrypoint
├── internal/cmd/shell_bash.go # BashEscape, bash hook
├── internal/cmd/shell_*.go    # per-shell adapters
├── internal/cmd/stdlib.go     # Go-side stdlib helpers
├── stdlib.sh                  # 1552 LOC bash stdlib
└── pkg/dotenv/parse.go        # .env parser (regex-based)

quickenv/                      # Rust, 1K LOC
├── src/main.rs                # CLI + bash wrapper + diff parser
├── src/core.rs                # envrc resolution, cache paths
├── src/grid.rs                # pretty-print unshimmed commands
└── src/signals.rs             # SIGINT passthrough to child

mise/                          # Rust, 336K LOC (overkill for reference)
├── src/env.rs                 # env building
├── src/hook_env.rs            # shell hook generation
├── src/env_diff.rs            # diff (vs direnv похоже)
├── src/config/env_directive/  # file/path/source/venv
└── src/cli/direnv/            # direnv interop (если есть .envrc — мост)
```
