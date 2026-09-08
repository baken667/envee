# ADR-010: Профили — декларативные overlays, environment-driven selection

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как user переключается между dev/staging/prod env без копипасты

## Контекст

В реальном проекте:
- `dev` — локальная БД, mock-платежи, debug logging.
- `staging` — копия prod, тестовые credentials, info logging.
- `prod` — реальные сервисы, real secrets, warn logging.
- Иногда: `feature/<name>` — ветка с экспериментальными фичами.

Текущие решения:
- **direnv**: `source_env .envrc.dev` (много копипасты).
- **mise**: `MISE_ENV=dev mise exec ...` (работает, но только через CLI, не через shell).
- **devenv**: Nix flakes, мощно, но кривая обучения.
- **shadowenv**: hard-coded, нет профилей.

## Решение

**Профили — first-class citizen** в `envee.toml`, selected через `ENVEE_PROFILE` env var или `--profile` flag.

### 1. Inline profile sections

```toml
schema = "envee/v1"
profile = "dev"  # default

[env]
SERVICE_NAME = "myapp"
LOG_LEVEL = "info"  # default value

[profiles.dev]
DATABASE_URL = "postgres://localhost/mydb_dev"
LOG_LEVEL = "debug"
DEBUG = true

[profiles.staging]
DATABASE_URL = "postgres://staging.example.com/mydb"
LOG_LEVEL = "info"

[profiles.prod]
DATABASE_URL = { value = "postgres://prod.example.com/mydb", required = true }
LOG_LEVEL = "warn"
required = ["DATABASE_URL", "SECRETS_MASTER_KEY"]  # profile-specific required
```

### 2. Profile-specific files (для больших конфигов)

```
envee.toml            # base + common profiles
envee.dev.toml        # dev-only overrides (loaded when ENVEE_PROFILE=dev)
envee.staging.toml
envee.prod.toml

# Personal overrides per profile
envee.local.dev.toml
envee.local.staging.toml
envee.local.prod.toml
```

**Приоритет** (высший → низший):
1. `envee.local.<profile>.toml` (cwd)
2. `envee.<profile>.toml` (cwd)
3. `envee.local.toml` (cwd)
4. `envee.toml` (cwd)
5. `envee.d/*.toml` (cwd)
6. (parent dirs...)
7. `~/.config/envee/config.toml`

### 3. Profile selection

**Precedence (high → low)**:
1. CLI flag: `envee --profile=prod eval bash`
2. Env var: `ENVEE_PROFILE=prod`
3. Auto-detect из git branch: `feature/prod-debug` → profile `prod` (если `profile_from_branch = true`).
4. `profile = "X"` в `envee.toml` (default).
5. Если ничего нет — `default` (пустой профиль, только base).

### 4. Profile inheritance

Профили могут extend другие:

```toml
[profiles.dev]
extends = ["common", "localstack"]  # загружает [profiles.common] и [profiles.localstack] первыми

[profiles.common]
LOG_LEVEL = "info"

[profiles.localstack]
AWS_ENDPOINT_URL = "http://localhost:4566"
```

**Семантика**:
1. Load `[profiles.common]`.
2. Load `[profiles.localstack]`.
3. Load `[profiles.dev]` (overrides everything).
4. Apply file overrides (per ADR-003 file hierarchy).

### 5. Multi-profile (composable)

```bash
ENVEE_PROFILE=dev,debug envee eval bash
# Загружает base → profiles.dev → profiles.debug → resolves env
```

Полезно для комбинирования: `dev,debug` = dev с extra debug logging.

### 6. Profile-specific required vars

```toml
[profiles.prod]
required = ["DATABASE_URL", "REDIS_URL", "API_KEY"]
```

Если `ENVEE_PROFILE=prod` и любая из required отсутствует → hard error:
```
[envee] ERROR: profile 'prod' requires: DATABASE_URL, REDIS_URL, API_KEY
[envee] HINT: set them in envee.local.toml, .env file, or via secrets plugin
```

### 7. Profile validation

`envee check` (статический анализ) валидирует:
- Все профили компилируются (TOML parse).
- Все `extends` chains — без циклов.
- Все `required` — выполнимы (есть default value или external source).
- Все `secret = "..."` — известный source.

### 8. Profile status

```bash
$ envee status --profile
Active profile: dev
Source: $ENVEE_PROFILE
Resolved from: /Users/alice/work/myproj/envee.toml

[dev]
extends: []
required: []
env overrides: DATABASE_URL, LOG_LEVEL, DEBUG

[staging]
required: []
env overrides: DATABASE_URL, LOG_LEVEL

[prod]
required: [DATABASE_URL, REDIS_URL, API_KEY]
env overrides: DATABASE_URL, LOG_LEVEL
```

### 9. Profile в IDE

`envee resolve --json --profile=dev` → машиночитаемый вывод, IDE плагин может показывать profile picker.

## Альтернативы

### Multiple `envee.*.toml` files (только)

**Плюсы**: просто.

**Минусы**: нет default'а, нет override'ов в одном файле, нет inheritance.

**Вердикт**: используем как **дополнение** к inline profiles (для больших конфигов).

### `MISE_ENV`-стиль (через отдельные файлы, override полное)

**Плюсы**: полная изоляция профилей.

**Минусы**: тяжело поддерживать общие куски (копипаста).

**Вердикт**: частично используем (через `envee.<profile>.toml`), но primary — inline.

### `mise.toml [env]` без профилей (только текущий env)

**Плюсы**: simple.

**Минусы**: для prod нужно менять `mise.toml` → коммит → re-deploy. Не dev-friendly.

**Вердикт**: не подходит.

### Per-shell function (`use_dev`, `use_prod`)

**Плюсы**: явный.

**Минусы**: bash-специфично, не работает в IDE, нужно помнить какие есть.

**Вердикт**: weak solution, мы лучше.

## Когда использовать каждый стиль

| Сценарий | Стиль |
|---|---|
| 2-3 профиля, мало overrides | Inline `[profiles.X]` |
| 5+ профилей, каждый большой | Отдельные `envee.X.toml` |
| Личные overrides для команды | `envee.local.<profile>.toml` (gitignored) |
| Динамические (CI matrix) | `ENVEE_PROFILE` env var + separate files |
| Multi-profile для debugging | `ENVEE_PROFILE=dev,debug` |

## Последствия

### Положительные

- Декларативно, видно глазами весь профиль в одном файле.
- Override на каждом уровне (file hierarchy).
- Extends для shared base.
- Required для fail-fast в production.
- Совместимо с `mise` mental model (плюс улучшения).

### Отрицательные

- Inline profiles делают `envee.toml` длиннее. Решение: профили в отдельных файлах для сложных случаев.
- Profile selection через git branch — controversial (непредсказуемо). Default = off.

### Нейтральные

- Multi-profile (`a,b`) — мощно, но может запутать. Default = single profile.
- `envee.toml.schema.json` нужно обновлять с каждым добавлением profile features.
