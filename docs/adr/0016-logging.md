# ADR-016: Logging & Observability — structured, env-driven, opt-in telemetry

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как выводить логи, диагностировать проблемы, и (опционально) собирать usage-аналитику

## Контекст

Логи нужны для:
1. **Debugging** — user жалуется "не работает", нужно понять почему.
2. **Audit** — кто, что, когда менял (secrets, trust).
3. **Performance** — bottleneck в eval? inotify не сработал?
4. **User-facing errors** — понятные сообщения, не stacktrace.

## Решение

### Stdlib logger: `log/slog` (Go 1.21+)

Структурированный JSON или text logs:

```go
// internal/log/log.go
import "log/slog"

func init() {
    handler := slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
        Level: parseLogLevel(os.Getenv("ENVEE_LOG")),
    })
    slog.SetDefault(slog.New(handler))
}

func parseLogLevel(s string) slog.Level {
    switch strings.ToLower(s) {
    case "trace": return slog.Level(-8)
    case "debug": return slog.LevelDebug
    case "info":  return slog.LevelInfo
    case "warn":  return slog.LevelWarn
    case "error": return slog.LevelError
    default:      return slog.LevelWarn
    }
}
```

### Уровни

| Level | Когда | Пример |
|---|---|---|
| `error` | Что-то сломалось, action required | Failed to load config |
| `warn` | Подозрительно, но не сломалось | Plugin uses stale cache |
| `info` | Significant event | Profile changed, secret resolved |
| `debug` | Diagnostic info | Loaded config from /path |
| `trace` | Very verbose | syscall details, every stat call |

**Default level**: `warn`. **User override**: `ENVEE_LOG=debug`.

### Output format

**Default (text)**: человекочитаемый.
```
[envee] WARN  plugin "op" using stale cache (cached 2h ago, expired 1h ago)
[envee] DEBUG config loaded path=/Users/alice/work/myproj/envee.toml took=2.3ms
```

**JSON mode** (`ENVEE_LOG=json`): для structured log aggregation.
```json
{"time":"2026-09-08T09:30:21Z","level":"WARN","msg":"plugin using stale cache","plugin":"op","cached_at":"2026-09-08T07:30:21Z","expires_at":"2026-09-08T08:30:21Z"}
```

### Output destination

**Default**: `os.Stderr` (не ломает pipe, не загрязняет `envee eval` output).

**Override**: `ENVEE_LOG_FILE=/path/to/file.log` — писать в файл (для debugging).

**File rotation**: **не** делаем (responsibility of OS logrotate). User настраивает.

### Когда логируем

**Always (info+)**:
- `envee.toml` loaded (path, hash, profile, elapsed).
- Trust granted / revoked.
- Secret resolved (без value, только metadata).
- Profile changed.
- Daemon started / stopped.

**Debug (opt-in)**:
- File watches added.
- Inotify events.
- Cache hit/miss.
- Plugin invocations (start, end, duration).

**Trace (opt-in, very verbose)**:
- Every syscall.
- Template evaluation steps.

**Never** (security):
- ❌ Secret values.
- ❌ Path to user's home (privacy).
- ❌ Stacktrace of internal error unless `--debug`.

### Sensitive redaction

```go
// internal/log/redact.go
func Redact(key, value string) string {
    if isSensitive(key) {
        return "***REDACTED***"
    }
    return value
}

func isSensitive(key string) bool {
    key = strings.ToUpper(key)
    return strings.Contains(key, "KEY") ||
        strings.Contains(key, "SECRET") ||
        strings.Contains(key, "TOKEN") ||
        strings.Contains(key, "PASSWORD") ||
        strings.Contains(key, "CREDENTIAL") ||
        strings.Contains(key, "AUTH")
}
```

Применяется в логах и в `envee status` (per ADR-009).

### User-facing output (не лог)

Для **eval** output — НЕ логирование, а сам результат. Идёт в stdout:

```bash
$ envee eval bash
export DATABASE_URL='postgres://localhost/dev';
export PATH='/Users/alice/work/myproj/bin:/usr/bin:/bin';
unset LEGACY_FLAG;
```

**Progress / status** — в stderr (не мешает pipe):
```bash
$ envee trust
[envee] Trusting envee.toml...          # stderr
Trusted.                                  # stdout (для скриптов)
  path:    /Users/alice/work/myproj/envee.toml
  hash:    sha256:abc123...
```

## Observability: diagnostic dump

`envee debug` (или `envee doctor --dump`) — собирает всю diagnostic info в один файл для sharing:

```bash
$ envee debug > envee-debug.txt 2>&1
# OR
$ envee debug --output envee-debug.zip
```

**Содержимое**:
```
=== envee version ===
0.5.0 (commit: abc123, built: 2026-09-08)

=== OS ===
Darwin 23.0.0 (arm64)

=== Shell ===
zsh 5.9 (default)

=== Config discovery ===
Resolved config files (priority high → low):
  1. /Users/alice/work/myproj/envee.local.toml
  2. /Users/alice/work/myproj/envee.toml
  3. /Users/alice/.config/envee/config.toml

=== Trust store ===
12 trusted entries, 0 denied
Recently used: op, aws

=== Daemon ===
Status: running (PID 12345, uptime 2h)
Socket: /var/folders/.../envee.sock
Cache: 42 entries, 3.2 MB

=== Plugins ===
op: 1.2.3 (api_version 1)
aws: 0.5.0 (api_version 1)

=== Performance (last 100 evals) ===
P50: 0.8ms, P95: 4.2ms, P99: 12.1ms
Slow eval: 145ms (config with 200 vars)

=== Logs (last 100 lines) ===
[envee] INFO  ...
[envee] DEBUG ...
```

**Включает**: env vars (`env`, без секретов), config files (resolved), recent logs.

**НЕ включает**: secret values, file contents из `config_root` (только paths), `~/.ssh/`, etc.

## Telemetry (opt-in, **default OFF**)

`ENVEE_TELEMETRY=1` — включает анонимный сбор usage-данных.

**Что собираем**:
- envee version, OS, arch.
- Какие subcommands вызываются (counters, не payloads).
- Plugin invocations (count, не values).
- Performance: P50/P95/P99 of eval latency.
- Error types (categorized: parse error, plugin error, etc.).

**Что НЕ собираем**:
- ❌ Env var names или values.
- ❌ Config file contents.
- ❌ File paths (кроме `config_root` для analytics distribution).
- ❌ User identity.

**Endpoint**: `https://telemetry.envee.dev/v1/events` (POST, JSON).

**Transport**: HTTPS, batched (every 5 min, or 100 events, whichever first).

**Schema** (event):
```json
{
  "schema_version": 1,
  "envee_version": "0.5.0",
  "event_type": "eval",
  "event_data": {
    "shell": "zsh",
    "elapsed_ms": 1.2,
    "cache_hit": true,
    "config_files": 3
  },
  "session_id": "uuid-v4-per-launch",
  "os": "darwin",
  "arch": "arm64"
}
```

**Opt-out**: `ENVEE_TELEMETRY=0` (explicit), `ENVEE_NO_TELEMETRY=1` (legacy), or `--no-telemetry` flag.

**Delete data**: `envee telemetry --delete` (отправляет deletion request, server purges).

**Source code**: telemetry client в `internal/telemetry/`, **open source**, можно проверить.

**Privacy policy**: `https://envee.dev/privacy` (публичный документ).

## Debug mode (`--debug`, `ENVEE_DEBUG=1`)

**Что включает**:
- Log level = debug.
- Печатает stacktrace при panic.
- Сохраняет core dump в `/tmp/envee-<pid>.core` (опционально).
- Больше verbose output.

**Когда использовать**: при bug reports. User делает:
```bash
$ envee --debug eval bash 2> debug.log > eval.sh
$ # отправляет debug.log разработчику
```

## Проблемы с shell hooks

**Главный pain point**: hooks вызываются на каждый prompt, **нельзя** спамить в stderr.

**Решения**:
- Default log level = `warn` (только важное).
- `--quiet` flag для hooks (или `ENVEE_QUIET=1`).
- Прогресс загрузки — `info` (видно при первом eval, не на каждом prompt).

```bash
_envee_hook() {
  local previous_exit_status=$?
  local out
  out="$("$ENVEE_BIN" --quiet eval bash 2>/dev/null)"
  local rc=$?
  if [[ $rc -eq 0 && -n "$out" ]]; then
    eval "$out"
  elif [[ $rc -ne 0 ]]; then
    return 0  # fail silently в hook
  fi
  return $previous_exit_status
}
```

**Critical errors** (config invalid, trust revoked) — печатаются даже в `--quiet`, но с rate limiting (max 1 раз per 5 min).

## Audit log

Отдельный лог-файл `$XDG_DATA_HOME/envee/audit.log` для security events.

**Включается**: `ENVEE_AUDIT=1` (default = off).

**События**:
- `trust_granted` / `trust_revoked`.
- `secret_resolved` (source, ref, user, cwd).
- `secret_cache_hit` / `secret_cache_miss`.
- `secret_cache_stale_used`.
- `config_loaded` (path, hash, profile).

**Format**: NDJSON (newline-delimited JSON) для easy `jq`/`grep`:
```json
{"ts":"2026-09-08T09:30:21Z","event":"secret_resolved","source":"op","ref":"op://Dev/Database/password","user":"alice","cwd":"/Users/alice/work/myproj","cache":"miss"}
```

**Не содержит**: values, file contents, env var values.

**Rotation**: user responsibility (`logrotate`).

## Health checks

`envee doctor` (без аргументов) — returns exit code + summary:

```bash
$ envee doctor
✓ envee 0.5.0 installed at /usr/local/bin/envee
✓ shell hook installed in ~/.zshrc
✓ no stale trust entries
⚠ 1 plugin out of date: aws (0.4.0 → 0.5.0 available)
✓ daemon running (PID 12345)

Diagnostics: 1 warning, 0 errors.
```

Exit code:
- `0` = OK.
- `1` = warnings.
- `2` = errors (something broken).

## Последствия

### Положительные

- `slog` — stdlib, zero dependencies.
- JSON-логи легко парсятся (ELK, Loki, Datadog).
- Telemetry opt-in (privacy first).
- `envee debug` — easy bug reports.
- Redaction из коробки.

### Отрицательные

- Telemetry endpoint нуждается в инфраструктуре (можно 3rd-party: PostHog, Sentry).
- Debug dumps могут случайно содержать sensitive data → auto-redaction critical.
- Multi-process logging (core + daemon) → нужно sync.

### Нейтральные

- Audit log отдельный, не в default logging.
- Health checks basic в MVP, расширяем в v2.x.
