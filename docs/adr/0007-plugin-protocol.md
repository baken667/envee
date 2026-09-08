# ADR-007: Plugin Protocol — exec-based с JSON-over-stdio

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как сторонние (и встроенные) плагины взаимодействуют с envee

## Контекст

Envee нужно расширяться без перекомпиляции ядра. Минимум:
- **Secret providers**: 1Password CLI, AWS, Vault, age, sops, Bitwarden, custom.
- **Tool integrations (опц.)**: node, python, go version resolvers (как у mise).
- **Source loaders (опц.)**: HTTP-источники для env-файлов.

Решения, которые мы выбираем сейчас, определят ecosystem velocity на годы вперёд.

## Решение

**Exec-based протокол** с **JSON-over-stdio**:

1. Плагин = executable в `$PATH` с префиксом `envee-plugin-` (например, `envee-plugin-1password`).
2. Core вызывает `envee-plugin-<name> <subcommand> [args...]`.
3. Subcommands: `metadata`, `resolve <request-json>`, `version`.
4. **Stdin**: опционально для больших inputs (binary files etc.).
5. **Stdout**: JSON response.
6. **Stderr**: логи, errors (не парсим).
7. **Exit code**: 0 = success, non-zero = error (с exit code 1 = generic, 2 = invalid input, 3 = auth required).

## Plugin discovery

```go
// internal/plugin/registry.go
type Registry struct {
    plugins map[string]Plugin
    mu      sync.RWMutex
}

func (r *Registry) Discover() error {
    // 1. Built-in plugins (compiled in, see internal/plugin/builtin/)
    for name, factory := range builtinPlugins {
        r.plugins[name] = factory()
    }
    
    // 2. User-installed plugins в $XDG_DATA_HOME/envee/plugins/<name>/
    userDir := filepath.Join(xdgDataHome, "envee", "plugins")
    for entry := range readDir(userDir) {
        if isExecutable(entry) {
            name := strings.TrimPrefix(entry.Name(), "envee-plugin-")
            r.plugins[name] = &ExecPlugin{path: entry.Path()}
        }
    }
    
    // 3. PATH-based plugins
    for _, name := range lookupPath("envee-plugin-*") {
        r.plugins[name] = &ExecPlugin{path: name}
    }
    
    return nil
}
```

## Protocol (v1)

### 1. `metadata`

```bash
$ envee-plugin-1password metadata
{
  "name": "1password",
  "version": "1.2.3",
  "api_version": 1,
  "description": "Resolve secrets from 1Password vaults",
  "capabilities": ["secret", "auth"],
  "permissions": {
    "network": true,
    "filesystem": ["read:~/Library/Group Containers/2BUA8C4S2C.com.1password/*"],
    "exec": ["/usr/local/op"]
  }
}
```

### 2. `resolve`

**Input (stdin, JSON)**:

```json
{
  "api_version": 1,
  "request_id": "uuid-v4",
  "spec": {
    "source": "op",
    "ref": "op://Dev/Database/password",
    "account": "my.1password.com",
    "vault": "Dev"
  },
  "context": {
    "config_root": "/Users/alice/work/myproj",
    "cwd": "/Users/alice/work/myproj",
    "profile": "dev",
    "env": {
      "HOME": "/Users/alice",
      "USER": "alice"
    }
  }
}
```

**Output (stdout, JSON)**:

```json
{
  "api_version": 1,
  "request_id": "uuid-v4",
  "status": "ok",
  "value": {
    "type": "string",
    "value": "hunter2"
  },
  "metadata": {
    "resolved_at": "2026-09-08T09:30:21Z",
    "ttl_seconds": 900,
    "source": "op://Dev/Database/password"
  }
}
```

**Error response**:

```json
{
  "api_version": 1,
  "request_id": "uuid-v4",
  "status": "error",
  "error": {
    "code": "auth_required",
    "message": "1Password CLI not signed in. Run 'op signin my.1password.com'.",
    "recoverable": true
  }
}
```

**Error codes (стандартный enum)**:
- `auth_required` — нужна аутентификация.
- `not_found` — секрет не найден.
- `permission_denied` — нет доступа.
- `network_error` — нет связи.
- `invalid_spec` — невалидный spec.
- `internal_error` — баг плагина.
- `quota_exceeded` — rate limit.

## Lifecycle плагина

```
[User runs envee trust, then envee eval]
     │
     ▼
[envee discovers plugin via PATH or builtin]
     │
     ▼
[envee calls `envee-plugin-X metadata` — кеширует capabilities]
     │
     ▼
[envee calls `envee-plugin-X resolve` с request]
     │
     ▼
[Plugin reads /exec, returns JSON]
     │
     ▼
[envee validates, applies to env]
     │
     ▼
[envee caches value в OS keyring с TTL из metadata.ttl_seconds]
```

## Concurrency

Core может вызывать **несколько плагинов параллельно** через goroutine pool (max 8 concurrent). Плагин — single-threaded внутри себя.

## Альтернативы

### HashiCorp go-plugin (gRPC)

**Плюсы**: type-safe, поддержка long-running daemon plugin, mature.

**Минусы**:
- Требует cgo или отдельный `plugin-protocol` бинарь.
- Сложнее для пользователя (нужно скачать 2 бинаря, не 1).
- Plugin crash → main process crash (если не используется Reattach).
- Heavy для нашего use case (большинство plugins — short-lived: resolve 1 secret).

**Вердикт**: отвергнут, overkill.

### HashiCorp plugin SDK (всё в одном binary)

**Плюсы**: type-safe через protobuf.

**Минусы**:
- Тот же gRPC overhead.
- Требует cgo в Core (в Go).

**Вердикт**: отвергнут.

### Pure Go plugins (`plugin.Open`)

**Плюсы**: type-safe, быстро.

**Минусы**:
- Только Linux/macOS, не работает на Windows.
- Plugin и Core должны быть скомпилированы одной версией Go.
- Критичные security issues (нет sandbox).

**Вердикт**: отвергнут, не портабельно.

### WebAssembly (вместо exec)

**Плюсы**: sandboxed, portable, type-safe через wit.

**Минусы**:
- WASM runtime overhead (~5-10ms cold start).
- Тяжелее писать плагины (нужен wit-файл, bindings).
- Сложнее для user, который хочет просто `op read "op://..."`.

**Вердикт**: reserved for v2.x, если plugins станут hot path.

### Native shared library (CGO)

**Плюсы**: быстро.

**Минусы**:
- ❌ cgo.
- ❌ Не кросс-компилируется.
- ❌ Different .so / .dylib / .dll на каждой платформе.

**Вердикт**: жёстко отвергнут.

## Почему exec-based

1. **Zero coupling**: плагин может быть на Python, Rust, Go, shell-скрипте — anything, что умеет парсить JSON.
2. **Process isolation**: краш плагина не валит core; security через capability list.
3. **Trivial install**: `brew install envee-plugin-1password` → оно в PATH → работает.
4. **Trivial debug**: `envee-plugin-1password resolve < input.json` — можно запустить руками.
5. **Cross-platform**: работает на всех ОС, поддерживаемых Go.
6. **No cgo**: статический бинарь, простая кросс-компиляция.

**Tradeoff**: каждый plugin call = fork+exec. Для short-lived resolve (типичный case) это OK (~10-30ms). Для hot path (per-prompt) — **нет**, поэтому core кеширует resolved values в OS keyring с TTL.

## Caching стратегия

```go
// internal/plugin/cache.go
type Cache struct {
    keyring keyring.Keyring
    ttl     time.Duration
}

func (c *Cache) Get(key string) (value []byte, ok bool, err error) {
    raw, err := c.keyring.Get(key)
    if err != nil { return nil, false, nil }
    
    var entry CachedEntry
    json.Unmarshal(raw, &entry)
    
    if time.Now().After(entry.ExpiresAt) {
        c.keyring.Delete(key)
        return nil, false, nil
    }
    
    return entry.Value, true, nil
}

func (c *Cache) Set(key string, value []byte, ttl time.Duration) error {
    entry := CachedEntry{
        Value:     value,
        CachedAt:  time.Now(),
        ExpiresAt: time.Now().Add(ttl),
    }
    raw, _ := json.Marshal(entry)
    return c.keyring.Set(key, raw)
}
```

Key format: `envee:plugin:<name>:<sha256(spec)>`.

**Важно**: cache key зависит от **spec**, не от request_id. Один и тот же `op://Dev/Database/password` всегда один ключ.

**TTL**: из `metadata.ttl_seconds` плагина. Default 15 min.

**Negative cache**: failed resolves тоже кешируются на короткий срок (60s) — чтобы не спамить при недоступности secret manager.

## Timeouts

| Operation | Default timeout |
|---|---|
| Plugin metadata | 5s |
| Plugin resolve | 10s |
| Network within plugin | зависит от плагина |

При timeout core возвращает error, **не пытается** повторить (чтобы не было бесконечного retry на каждом prompt).

## Built-in plugins (MVP)

В MVP **только один встроенный плагин**: `op` (1Password CLI wrapper). Остальные — `envee plugin install` через Homebrew или скрипт.

| Plugin | Зависимость | Maintainer |
|---|---|---|
| `op` (1Password) | `op` CLI | envee-core |
| `aws` (Secrets Manager + SSO) | AWS SDK | envee-core |
| `vault` (HashiCorp Vault) | `vault` CLI | envee-core |
| `sops` (Mozilla SOPS) | `sops` CLI | envee-core |
| `age` (age encryption) | `age` CLI | envee-core |
| `bw` (Bitwarden) | `bw` CLI | envee-core |
| `keyring` (OS keyring) | none | envee-core |

Все built-in плагины — **отдельные бинари** в `plugins/<name>/cmd/`, не вкомпилированы в core. Это:
- Decouples release cycles (плагин обновился → пользователь делает `brew upgrade envee-plugin-op`, не весь envee).
- Позволяет community-контрибьюторам форкать/улучшать плагины независимо.

## Plugin metadata file (для discoverability)

`~/.local/share/envee/plugins/<name>/metadata.json` — кешированный metadata плагина. Если его нет — envee вызывает `envee-plugin-<name> metadata` заново. TTL кеша = 24 часа, invalidation при изменении бинаря (по mtime).

## Security considerations

1. **Plugin permission manifest** (`metadata.permissions`): плагин декларирует, что ему нужно. Core пишет warning в `envee status` если plugin требует network/exec, а user не дал explicit consent в trust-file.

2. **Plugin signature verification** (Phase 3): Homebrew ставит `envee-plugin-X` через verified SHA256 checksums. Для community-плагинов — opt-in GPG/cosign signature.

3. **No silent exec**: если плагин хочет вызвать `op` (subprocess), это должно быть в `metadata.permissions.exec`, и envee спросит пользователя при trust'е.

4. **No automatic upgrades**: плагин обновляется через `brew upgrade` или `apt upgrade`, не через envee.

## Plugin SDK (Go, v1)

`github.com/baken667/envee-plugin-sdk-go/plugin` — helper для plugin authors:

```go
package main

import (
    "encoding/json"
    "os"
    "github.com/baken667/envee-plugin-sdk-go/plugin"
)

func main() {
    plugin.Run(plugin.Plugin{
        Metadata: plugin.Metadata{
            Name: "my-plugin",
            Version: "0.1.0",
            Capabilities: []string{"secret"},
        },
        Resolve: func(req plugin.Request) (plugin.Response, error) {
            // ...
            return plugin.Response{
                Value: plugin.Value{Type: "string", Value: "secret"},
            }, nil
        },
    })
}
```

Plugin SDK скрывает JSON-IO, error mapping, request_id correlation.

## Versioning protocol

`api_version: 1` в каждом request/response. При несовпадении — error.

**Breaking change policy**:
- `api_version` bump требует `protocol_version` в metadata.
- Core **обязан** поддерживать текущую + предыдущую major version.
- Старые плагины работают через compatibility shim.

## Последствия

### Положительные

- Trivial onboarding для community (любой язык, любой опыт).
- Crash isolation, security boundaries.
- Простая debugging story.
- Cross-platform без cgo.
- Pluggable secret providers — критично для enterprise adoption.

### Отрицательные

- fork+exec overhead (~10-30ms per call). Mitigated кешем.
- Type safety: ошибки в JSON схеме — runtime, не compile-time. Mitigated SDK + JSON Schema validation.
- Plugin updates вне core release cycle — пользователь должен помнить про `brew upgrade`.

### Нейтральные

- 7 встроенных плагинов — это 7 subrepos в monorepo (или 7 сторонних пакетов). Решим в Phase 3.
