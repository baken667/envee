# ADR-009: Secrets — плагинная модель + OS keyring cache + redaction by default

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как безопасно и удобно работать с секретами в env

## Контекст

Главный use-case envee — **per-project env с секретами**. Проблемы:
- Секреты нельзя коммитить (GitHub/GitLab secret scanning → fail CI).
- Секреты нельзя класть в `.env` (тоже leak risk).
- Секреты должны быть **доступны локально** разработчику (но не в git).
- Разные секрет-сторы: 1Password, AWS Secrets Manager, Vault, Bitwarden, age-encrypted files, SOPS-encrypted YAML.

## Решение

**Три слоя**:

### Layer 1: `_.secret.<NAME>` в TOML (декларативно)

```toml
[env]
# Из 1Password
DATABASE_PASSWORD = { secret = "op://Dev/Database/password", redact = true }
GITHUB_TOKEN = { secret = { source = "op", ref = "op://Personal/GitHub/token" } }

# Из AWS Secrets Manager
AWS_DB_CREDS = { secret = "aws://secretsmanager/dev/db", redact = true }

# Из HashiCorp Vault
VAULT_TOKEN = { secret = "vault://secret/data/dev#token", redact = true }

# Из локального age-encrypted файла
LOCAL_API_KEY = { secret = "age://./secrets.age#api_key", redact = true }
```

**Source URI scheme**: `<source>://<ref>`. Plugin сам парсит ref по своему формату.

### Layer 2: Plugin resolve (по ADR-007)

Plugin получает `{source, ref, ...}` через stdin, возвращает `{value, ttl}`. Core кеширует в OS keyring (см. Layer 3).

### Layer 3: OS keyring cache

`github.com/zalando/go-keyring` (cross-platform):
- macOS: Keychain.
- Linux: Secret Service (GNOME Keyring, KWallet).
- Windows: Credential Manager.

**Cache key**: `envee:secret:<sha256(source_uri)>`.

**Cache value**: `{"value": "...", "cached_at": "...", "expires_at": "..."}` (JSON, msgpack-encoded).

**TTL**: из plugin metadata `ttl_seconds` (default 900s = 15 min).

**Stale-on-error**: если plugin возвращает error, но в keyring есть stale value (expired) — **используем stale value** + warning. Это позволяет работать offline если secret manager недоступен (network blip).

```go
// internal/secret/cache.go
func (c *Cache) GetOrFetch(key, sourceURI string, fetch func() (string, time.Duration, error)) (string, error) {
    // 1. Try fresh cache
    if val, err := c.get(key); err == nil && !c.isExpired(val, 0) {
        return val.Value, nil
    }
    
    // 2. Fetch from plugin
    newVal, ttl, err := fetch()
    if err == nil {
        c.set(key, newVal, ttl)
        return newVal, nil
    }
    
    // 3. Stale fallback
    if staleVal, _ := c.get(key); staleVal != nil {
        log.Warn("using stale cached secret (offline?): %v", err)
        return staleVal.Value, nil
    }
    
    return "", err
}
```

## Redaction

**Default redaction для `_.secret.*`**: переменная помечается как `redact = true` автоматически, даже если user не указал.

**Manual redaction для обычных переменных**: `redact = true` в inline table.

**Что маскируется**:
- `envee status` — показывает `DATABASE_PASSWORD=***`.
- `envee resolve --json` — JSON содержит `"DATABASE_PASSWORD": {"redacted": true}` (без value).
- `envee eval` в stderr/логах — то же самое.

**Что НЕ маскируется**:
- Само значение в `envee eval $SHELL` (это eval'нется в shell и попадёт в env — это и есть цель).
- Subprocess env, который унаследовал значение.

**Explicit reveal** (для debugging):

```bash
envee status --show-secrets   # требует interactive confirmation
# или
ENVEE_REDACT=false envee status  # для скриптов
```

## Trust model для секретов

`_.secret.*` ссылки требуют **отдельного trust'а** для каждого источника:

```bash
$ envee trust
Trust this envee.toml? [Y/n/d(iff)] y
Trusted.

[envee] ⚠ secrets detected. Trust secret sources?
  - op (1Password) — requires 'op' CLI + 1Password subscription
  - aws (AWS) — requires AWS credentials
  Trust all? [a/n/s(kip)/d(iff)] d
  --- envee.toml
  +++ trusted
  @@ -10,3 +10,3 @@
  -DATABASE_PASSWORD = { secret = "op://Dev/Database/password" }
  +DATABASE_PASSWORD = { secret = "op://Dev/Database/password", trusted_at = "..." }

Trust op? [Y/n] y
Trusted. 1 secret source: op.

[envee] (next time) Use `envee trust --secrets-only` to re-review secrets.
```

**Secret trust cache** — отдельный файл `$XDG_DATA_HOME/envee/trust/secrets.json`:

```json
{
  "version": 1,
  "sources": {
    "op": {
      "trusted_at": "2026-09-08T09:30:21Z",
      "trusted_by": "alice",
      "path_patterns": ["op://Dev/*", "op://Personal/*"],
      "last_used": "2026-09-08T09:35:00Z"
    }
  }
}
```

Path patterns allow user to constrain trust (e.g., "trust all `op://Dev/*` but ask again for `op://Production/*`").

## Plugin-specific security

### `op` (1Password)

- Требует signed-in `op` CLI (или biometric).
- Может работать с biometric prompt вместо password (на macOS, через `op signin --use-biometric`).
- Плагин не хранит пароли, только делегирует к `op` CLI.

### `aws` (AWS Secrets Manager + SSO)

- Использует default AWS SDK chain (env vars, ~/.aws/credentials, IAM role).
- Для SSO — `aws sso login` flow.
- IAM permissions контролируются через policy на стороне AWS.

### `vault` (HashiCorp Vault)

- Использует `VAULT_TOKEN` env или `~/.vault-token` file.
- Periodic token renewal — handled by Vault side.
- AppRole / Kubernetes auth — opt-in через plugin config.

### `age` (file encryption)

- Decrypts `.age` files locally using `~/.config/age/keys.txt` (or env-supplied identity).
- Подходит для **sealed secrets** в git (коммитится encrypted, decrypt локально).
- Plugin НЕ хранит identity (это ответственность user'а).

### `sops`

- Использует `sops` CLI для decrypt YAML/JSON файлов.
- Поддерживает KMS, age, PGP keys.

### `keyring` (OS keyring only)

- Для тех, кто хочет вручную положить secret в Keychain.
- UI через `envee secret set <name>`.

## Encryption at rest

- Trust-store и cache — plain JSON в v1.x (per ADR-004, encryption в v2.x).
- Secret values в OS keyring — encrypted by OS (Keychain, libsecret, DPAPI).
- Envee binary не имеет доступа к keyring master key — relies on OS.

## Audit log

Каждый secret resolve логируется:

```
[2026-09-08T09:30:21Z] secret_resolved source=op ref=op://Dev/Database/password user=alice cwd=/Users/alice/work/myproj
[2026-09-08T09:30:21Z] secret_cache_hit key=sha256:abc... user=alice
```

Лог пишется в `$XDG_DATA_HOME/envee/audit.log` (опционально, через `ENVEE_AUDIT=1`).

**Не логируем** само значение секрета. Только metadata: source, ref, user, cwd, cache hit/miss.

## Edge cases

### CI / no-keyring environment

В CI обычно нет keyring. Поведение:
- Cache get/set → silent no-op (не error).
- Каждый resolve = plugin call (более медленно).
- User может установить `ENVEE_SECRET_NO_CACHE=1` для явности.

### Secret rotation

Если secret изменился в source (e.g., rotated in Vault), но cache TTL не истёк — envee будет возвращать stale value. Mitigations:
- User может сделать `envee invalidate --secret <name>` (force re-fetch).
- TTL обычно 15 min, что достаточно для dev workflow.
- Production deploys — через CI с `ENVEE_SECRET_NO_CACHE=1`.

### Offline mode

Если secret manager недоступен (network), но cache есть — **stale value используется** (per GetOrFetch). User видит warning в `envee status`:
```
[envee] ⚠ 2 secrets using stale cache (offline?):
  - DATABASE_PASSWORD (cached 2h ago, expired 1h45m ago)
  - GITHUB_TOKEN (cached 30m ago, expired 15m ago)
```

User может `--strict` для fail при stale.

## UX

```bash
# Проверить, какие секреты будут запрошены (dry run)
$ envee resolve --dry-run
[env]
DATABASE_PASSWORD = { secret = "op://Dev/Database/password" }
GITHUB_TOKEN = { secret = "op://Personal/GitHub/token" }

# Без `--dry-run` — реально резолвит
$ envee resolve
[env]
DATABASE_PASSWORD = "hunter2"   # показывается, если ENVEE_REDACT=false
GITHUB_TOKEN = "ghp_xxxxx"

# JSON output для tooling
$ envee resolve --json | jq '.env'
{
  "DATABASE_PASSWORD": "hunter2",
  "GITHUB_TOKEN": "ghp_xxxxx"
}
```

## Последствия

### Положительные

- Декларативно — секреты описаны в `envee.toml`, а не разбросаны по скриптам.
- `redact = true` по дефолту — `envee status` безопасен для шаринга.
- Plugin model — community может добавлять новые источники.
- OS keyring cache — быстро (10ms vs 100ms для plugin call) + работает offline.
- Audit log — для security review.

### Отрицательные

- Plugin для каждого source = 1 бинарь в PATH. У пользователя может не быть нужного.
- Trust для секретов — дополнительный UX шаг. Можно auto-approve, но security risk.
- Stale-cache fallback — может маскировать реальные проблемы (rotated secrets, revoked access).

### Нейтральные

- Audit log — privacy concern? User должен явно включить. Default = off.
- В v2.x — encryption trust-store, encrypted cache, full audit.
