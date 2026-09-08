# ADR-015: Versioning — SemVer strict, fast minor, slow major

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как версионировать API/CLI/конфиг-схему, чтобы не сломать user'ам рабочий процесс

## Контекст

Версионировать нужно:
1. **envee binary** (CLI).
2. **Protocol API** (plugin protocol v1).
3. **Config schema** (`envee/v1`).
4. **Trust-store format** (v1 в нашем JSON).
5. **Templates API** (WASM host ABI).

Если все эти versioning схемы смешать — пользователи получат break на каждом minor. Если изолировать — можем двигаться быстро.

## Решение

**SemVer 2.0** для **binary** (CLI).

**Независимые version tokens** для остальных подсистем:
- `schema = "envee/v1"` в TOML → пиннинг config schema.
- `api_version: 1` в plugin protocol.
- `version: 1` в trust-store JSON.
- ABI version embedded в WASM module.

## SemVer для binary

**Format**: `MAJOR.MINOR.PATCH` (например, `0.4.2`).

**Pre-1.0** (`0.x.y`): minor == breaking. После `1.0.0` — strict semver.

### Правила

| Изменение | Версия |
|---|---|
| Bug fix (не меняет behavior) | patch |
| New subcommand | minor |
| New flag для существующего subcommand | minor |
| New `_.` directive | minor |
| New template filter | minor |
| Изменение формата `envee resolve --json` (additive) | minor |
| Изменение формата `envee resolve --json` (breaking) | major |
| Удаление subcommand | major |
| Удаление `_.` directive | major |
| Изменение default'ов (например, default `disable_stdin`) | major |
| Изменение shell hook output format (breaking) | major |
| Изменение env var имен (например, `ENVEE_*`) | major (с deprecation period) |

### Deprecation process

1. **Mark deprecated** в `0.MINOR.0` (warning в output).
2. **Document в CHANGELOG** + migration guide.
3. **Continue работать** ещё 2 minor versions.
4. **Remove** в next major.

Пример: `envee --debug` deprecated в `0.5.0`, удалён в `1.0.0`. Warning:
```
[envee] WARN: --debug is deprecated, use --log-level=debug
[envee]       Will be removed in v1.0.0
```

## Config schema versioning

**Пиннинг в `envee.toml`**:

```toml
schema = "envee/v1"  # current
```

**Поддерживаемые схемы**:
- `envee/v1` — current (MVP).
- `envee/v2` — breaking changes в schema (когда будут).

**Поведение**:
- Файл с `schema = "envee/v1"` + envee binary v0.5.x → OK.
- Файл с `schema = "envee/v1"` + envee binary v0.4.x → ERROR (binary не знает `v1`).
- Файл с `schema = "envee/v2"` + envee binary v0.5.x → ERROR (binary не знает `v2`, нужен upgrade).

**Без `schema` поля** — warning, default = `envee/v1` (latest known).

```toml
# Default behavior в v0.x — warning
schema = "envee/v1"  # auto-added if missing, with warning
```

## Plugin protocol versioning

**В metadata response**:
```json
{
  "name": "1password",
  "version": "1.2.3",
  "api_version": 1,
  "min_envee_version": "0.4.0"
}
```

**В request**:
```json
{
  "api_version": 1,
  "request_id": "uuid",
  "spec": {...}
}
```

**Совместимость**:
- Core **обязан** поддерживать `api_version` от 1 до current (например, 1-3).
- Plugin может декларировать `min_envee_version` — core проверяет при trust'е.
- Если plugin `api_version > core.api_version_max` → error при resolve.

**Bump**:
- `api_version: 2` добавляет **optional** fields.
- Breaking change (удаление поля, изменение типа) → bump до `3`.

**Плагин может декларировать support ranges**:
```json
{
  "api_version": 1,
  "supports_api_versions": [1, 2, 3]
}
```

## Trust-store versioning

**В каждом trust file**:
```json
{
  "version": 1,         // trust-store format version
  "file_hash": "...",
  ...
}
```

**При загрузке**: core читает `version`, если > известного → error.

**При upgrade**: trust-store migration tool (one-time):
```bash
$ envee trust migrate
Migrating trust-store from v0 to v1...
✓ Migrated 12 trust entries.
```

## WASM ABI versioning

**В WASM module exports**:
```rust
#[no_mangle]
pub static ENVEE_ABI_VERSION: u32 = 1;
```

Core проверяет при load, mismatch → error.

## Release cadence

| Release type | Cadence | Пример |
|---|---|---|
| Patch | as needed (bug fixes) | `0.4.0` → `0.4.1` (через 2 недели) |
| Minor | monthly | `0.4.x` → `0.5.0` (каждое 4-ое число) |
| Major | quarterly+ | `0.x` → `1.0.0` (когда API stable) |

**Calendar versioning** (не используем):
- ❌ `2026.09.08` — нет semver, сложно сравнивать.

**CalVer в CHANGELOG**: yes, дополнительно (для humans):
```markdown
## v0.4.0 (2026-09-08)
```

## LTS (Long Term Support) versions

После `1.0.0` объявляем **LTS versions** (например, `1.0.x`, `1.5.x`).

- **LTS bug fixes** — 12 months support.
- **Current** — 6 months.
- **Old LTS** — security fixes only, 3 months.

Сейчас (pre-1.0) — все версии current.

## Backport policy

**Active branches** (после 1.0):
- `main` — development for next minor.
- `release-1.0.x` — bug fixes only.
- `release-1.1.x` — bug fixes for 1.1 LTS.

**Cherry-pick policy**: bug fix из `main` → backport в `release-X.Y` если применимо.

**Теги в git**:
- `v0.4.0`, `v0.4.1`, ...
- `v0.4.0-rc.1`, `v0.4.0-beta.1` (pre-releases).

## Deprecation warnings

**В CLI output**:
- Stderr (не stdout) → не ломает pipe.
- Префикс `[envee] WARN: `.
- Reference на docs: `https://envee.dev/deprecations/<name>`.

**Examples**:
```
[envee] WARN: envee.toml без `schema` поля устарел. Добавьте `schema = "envee/v1"`.
[envee]       Will be required in v1.0.0
[envee]       Docs: https://envee.dev/deprecations/schema-required

[envee] WARN: $ENVEE_DAEMON_SOCK устарел, используйте $ENVEE_DAEMON_SOCKET.
[envee]       Will be removed in v0.7.0

[envee] WARN: profile 'X' extends profile 'Y' который deprecated.
[envee]       См. https://envee.dev/migrations/Y-removed
```

## Compatibility matrix

В README публикуем:

| Envee version | Config schema | Plugin API | Trust-store | WASM ABI | Released | EOL |
|---|---|---|---|---|---|---|
| 0.5.x | envee/v1 | 1 | 1 | 1 | 2026-09 | TBD |
| 0.4.x | envee/v1 | 1 | 1 | 1 | 2026-08 | TBD |
| 1.0.x (LTS) | envee/v1 | 1-2 | 1 | 1 | TBD | TBD+12mo |

## Backwards compatibility commitment

**Stable** (после 1.0.0):
- `envee.toml` schema **v1** — supported до 2.0 (минимум 12 months).
- Plugin API **v1** — supported до v3 (минимум 12 months после v2 release).
- Trust-store **v1** — supported indefinitely (migration tool).

**Unstable** (pre-1.0):
- Все APIs могут измениться в любой minor release.
- Deprecation warnings, но без deprecation period.

## Migration tools

`envee upgrade` (встроенная команда):
- Проверяет `envee.toml` против текущей версии.
- Если есть migration path — apply автоматически (с backup).
- Если нет — clear error с manual steps.

`envee upgrade --from 0.4 --to 0.5` — explicit version migration.

## Communicating changes

**Каналы**:
- CHANGELOG.md (в репо, auto-generated из conventional commits).
- GitHub Releases (через GoReleaser).
- `envee status` output (если running устаревшая версия):
  ```
  [envee] INFO: envee 0.6.0 available. Run `brew upgrade envee` or download from https://envee.dev/download
  ```
- RSS / Atom feed на `envee.dev/feed.xml`.
- Twitter / X (announcements, не support).

## Breaking change policy (для maintainer'а)

**Перед breaking change**:
1. Создать GitHub issue с тегом `breaking-change`.
2. Discussion (минимум 1 week).
3. Proposal в `docs/proposals/`.
4. Implementation.
5. Deprecation period (1 minor).
6. Removal в next major.

**Cost of breaking change = high** (ломаем user'ов). Default = avoid.

## Последствия

### Положительные

- Strict semver → user'ы могут trust'ить API.
- Schema/API pinning → user'ы фиксируют версию в `envee.toml`.
- Deprecation period → user'ы имеют время migrate.
- Compatibility matrix → transparency.

### Отрицательные

- Pre-1.0 = fast churn (user'ы должны часто обновляться).
- Поддержка N версий одновременно (после 1.0) = overhead.
- Migration tools — extra code.

### Нейтральные

- Multi-dimensional versioning (CLI vs config vs plugin) — нужно документировать.
- LTS policy — после 1.0.
