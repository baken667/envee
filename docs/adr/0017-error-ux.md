# ADR-017: Error UX — actionable messages с HINT и DOC ссылками

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как сообщать об ошибках так, чтобы user понимал, что делать

## Контекст

Плохие error messages — топ-1 причина, почему люди ненавидят CLI tools.

Хорошие:
- Понятно что сломалось.
- Понятно где искать.
- Понятно как починить.

Пример плохого (direnv):
```
direnv: error .envrc is blocked
```
(непонятно: почему blocked? как разблокировать? какая команда?)

Пример хорошего:
```
[envee] ERROR: envee.toml at /Users/alice/work/myproj is not trusted.
[envee] HINT:  Run `envee trust` to approve its content.
[envee] DOC:   https://envee.dev/trust
```

## Решение

### Структура error message

Каждое error сообщение состоит из **4 частей**:

1. **Severity** (ERROR / WARN / INFO).
2. **Message** — что произошло (1 строка).
3. **Context** — где произошло (path, key, value snippet).
4. **Hint** — как починить (action, command).
5. **Doc link** (опционально) — где почитать подробнее.

### Реализация

```go
// internal/errs/errs.go
type Error struct {
    Severity Severity
    Summary  string             // "envee.toml is not trusted"
    Context  map[string]string  // {"path": "/Users/...", "hash": "sha256:abc..."}
    Hint     string             // "Run `envee trust` to approve its content."
    Doc      string             // "https://envee.dev/errors/E001"
    Cause    error              // wrapped underlying error (if any)
}

func (e *Error) Error() string {
    var b strings.Builder
    
    // Severity prefix
    b.WriteString(fmt.Sprintf("[envee] %s: %s\n", e.Severity, e.Summary))
    
    // Context
    if len(e.Context) > 0 {
        keys := sortedKeys(e.Context)
        for _, k := range keys {
            b.WriteString(fmt.Sprintf("[envee]   %s: %s\n", k, e.Context[k]))
        }
    }
    
    // Hint
    if e.Hint != "" {
        b.WriteString(fmt.Sprintf("[envee] HINT: %s\n", e.Hint))
    }
    
    // Doc
    if e.Doc != "" {
        b.WriteString(fmt.Sprintf("[envee] DOC:  %s\n", e.Doc))
    }
    
    // Cause (debug mode)
    if e.Cause != nil && debugMode {
        b.WriteString(fmt.Sprintf("[envee] CAUSE: %v\n", e.Cause))
    }
    
    return b.String()
}
```

### Error codes (для docs и machine parsing)

Каждая категория error имеет стабильный code (E001, E002, ...):

| Code | Категория | Doc URL |
|---|---|---|
| E001 | Trust required | envee.dev/errors/E001 |
| E002 | Config parse error | envee.dev/errors/E002 |
| E003 | Config validation error | envee.dev/errors/E003 |
| E004 | Secret plugin error | envee.dev/errors/E004 |
| E005 | Template render error | envee.dev/errors/E005 |
| E006 | WASM script error | envee.dev/errors/E006 |
| E007 | Cycle detected | envee.dev/errors/E007 |
| E008 | Required var missing | envee.dev/errors/E008 |
| E009 | Plugin not found | envee.dev/errors/E009 |
| E010 | Trust denied | envee.dev/errors/E010 |
| E011 | Daemon error | envee.dev/errors/E011 |
| E012 | File not found | envee.dev/errors/E012 |
| E013 | Permission denied | envee.dev/errors/E013 |
| E014 | Version incompatible | envee.dev/errors/E014 |
| E015 | Network error | envee.dev/errors/E015 |

### Exit codes

| Code | Когда |
|---|---|
| 0 | Success |
| 1 | Generic error |
| 2 | Invalid usage (bad args) |
| 3 | Trust required (user can fix by `envee trust`) |
| 4 | Config error (user must fix TOML) |
| 5 | Plugin error (check plugin install / network) |
| 6 | Internal error (bug; report with `envee debug`) |
| 64-78 | sysexits.h convention (EX_USAGE=64, EX_DATAERR=65, etc.) |

**Shell-friendly**: exit code = индикатор для shell pipelines:
```bash
$ envee eval bash > eval.sh || {
    case $? in
      3) echo "Run envee trust first" ;;
      4) echo "Fix your envee.toml" ;;
      *) echo "Unknown error" ;;
    esac
}
```

### Примеры error messages

#### Trust required

```
[envee] ERROR [E001]: envee.toml is not trusted.
[envee]   path: /Users/alice/work/myproj/envee.toml
[envee]   hash: sha256:abc123def456...
[envee] HINT:  Run `envee trust` to review and approve.
[envee] DOC:   https://envee.dev/errors/E001
```

#### Config syntax error

```
[envee] ERROR [E002]: failed to parse envee.toml.
[envee]   path: /Users/alice/work/myproj/envee.toml
[envee]   line: 12, column: 5
[envee]   expected: '=' (key-value separator)
[envee] HINT:  Check TOML syntax at the indicated line.
[envee] DOC:   https://envee.dev/errors/E002
```

#### Required var missing

```
[envee] ERROR [E008]: required variable not defined.
[envee]   variable: DATABASE_URL
[envee]   profile:  prod
[envee] HINT:  Set in envee.toml, .env file, or via secret plugin.
[envee] DOC:   https://envee.dev/errors/E008
```

#### Plugin not found

```
[envee] ERROR [E009]: secret plugin not found.
[envee]   source:  op
[envee]   plugin:  envee-plugin-op
[envee] HINT:  Install with: brew install baken/tap/envee-plugin-op
[envee] HINT:  Or via Go:    go install github.com/baken667/envee-plugins/op@latest
[envee] DOC:   https://envee.dev/errors/E009
```

#### Cycle detected

```
[envee] ERROR [E007]: circular dependency in template.
[envee]   chain: DATABASE_URL → env.DB_HOST → env.DATABASE_URL
[envee] HINT:  Break the cycle by using a constant value.
[envee] DOC:   https://envee.dev/errors/E007
```

#### Permission denied

```
[envee] ERROR [E013]: permission denied.
[envee]   path:  /Users/alice/.local/share/envee/trust/abc.json
[envee]   user:  alice (uid 501)
[envee]   owner: root (uid 0)
[envee] HINT:  Run `chown -R alice:staff ~/.local/share/envee/`
[envee] DOC:   https://envee.dev/errors/E013
```

### Recovery (recovery actions)

Некоторые errors предлагают **автоматическое recovery**:

```
[envee] ERROR [E013]: permission denied.
[envee] HINT:  Run `sudo chown -R alice:staff ~/.local/share/envee/` (requires password)
[envee] RECOVER: Try `envee trust --migrate` to fix common issues? [y/N]
```

**Только для safe operations** (chown, не rm -rf).

### TUI для trust (Phase 3)

`envee trust` в интерактивном режиме:

```
Trust this envee.toml? /Users/alice/work/myproj/envee.toml

[envee.toml content rendered in pager with syntax highlight]
...

Summary:
  • 12 env vars
  • 3 PATH additions
  • 1 secret source: op
  • 0 scripts

Security check:
  ✓ no bash scripts
  ✓ all secrets use known plugins
  ⚠ SECRET_KEY: no redact=true (variable name suggests secret)

Trust? [Y/n/d(iff)/s(how)/q(uit)] d
--- /Users/alice/work/myproj/envee.toml
+++ (new)
[diff output]

Trust? [Y/n/d/s/q] y
Trusted. hash: sha256:abc...
```

**В неинтерактивном режиме** (`envee trust --yes`):
- Без TTY — auto-trust (только если `--yes`).
- С TTY — TUI prompt.

### Multi-error reporting

При resolve может быть несколько errors (несколько required vars missing, несколько plugins failed):

```
[envee] ERROR: 3 issues found:
  1. [E008] DATABASE_URL required but not defined
  2. [E008] REDIS_URL required but not defined
  3. [E009] plugin 'op' not found

[envee] HINT:  Fix all issues above, then re-run `envee eval`.
```

**Default behavior**: показываем все errors сразу, не fail-fast.

### Machine-readable errors (`--json`)

```bash
$ envee eval --json-error bash 2> errors.json
```

```json
{
  "errors": [
    {
      "code": "E001",
      "severity": "error",
      "summary": "envee.toml is not trusted",
      "context": {"path": "/Users/.../envee.toml", "hash": "sha256:abc..."},
      "hint": "Run `envee trust` to approve its content.",
      "doc": "https://envee.dev/errors/E001"
    }
  ]
}
```

Для IDE-плагинов: парсят JSON, показывают в UI с rich formatting.

### Localization (i18n, v2.x)

В v1.x — только English. В v2.x:
- `ENVEE_LANG=ru` / `de` / `zh` / etc.
- Translation через `golang.org/x/text/language` + PO files.
- Crowdin / Weblate для community translations.

**В v1.x — English everywhere**, как простой baseline.

## Цвет в выводе

**Default**: если stderr = TTY, цвет включён. Иначе — plain text.

**Force**: `ENVEE_COLOR=always` / `never` / `auto`.

**Цвета**:
- `ERROR` = red.
- `WARN` = yellow.
- `INFO` = cyan.
- `HINT` = green (actionable!).
- `DOC` = blue (link).

**Реализация**: `github.com/fatih/color` или `github.com/charmbracelet/lipgloss` (TUI).

## Testing errors

**Snapshot tests** для error messages:

```go
// internal/errs/errs_test.go
func TestTrustRequired(t *testing.T) {
    e := &errs.Error{
        Code: "E001",
        Severity: errs.Error,
        Summary: "envee.toml is not trusted",
        Context: map[string]string{"path": "/tmp/test/envee.toml"},
        Hint: "Run `envee trust` to approve its content.",
    }
    got := e.Error()
    golden.Assert(t, got, "trust_required.golden")
}
```

CI проверяет, что error messages не меняются (или меняются **явно** через update snapshot).

## Последствия

### Положительные

- User-friendly ошибки с actionable hints.
- Документированные error codes (E001, E002, ...).
- Machine-readable JSON для tooling.
- Multi-error reporting — все issues сразу.
- Recovery actions для safe fixes.

### Отрицательные

- Verbose output (5 строк на 1 ошибку) — иногда шумно.
- Doc URLs нужно поддерживать актуальными.
- TUI mode (Phase 3) — extra complexity.

### Нейтральные

- v1.x English only, i18n в v2.x.
- Exit codes: 6 категорий, может расширяться.
