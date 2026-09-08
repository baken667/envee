# ADR-002: Формат конфига — TOML 1.0

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: В каком формате описывать `envee.toml`

## Контекст

Нужен human-editable config с поддержкой:
- Простых скаляров (string/int/bool).
- Вложенных структур (для `required`, `redact`, profile overlays).
- Массивов (для `_.path` списка директорий).
- JSON Schema для валидации.
- Хорошей читаемости (проект будут открывать глазами в PR-ревью).
- Поддержки в редакторах (LSP, syntax highlight).

## Решение

**TOML 1.0** как основной формат (`envee.toml`).

## Альтернативы, которые рассмотрели

### YAML

**Плюсы**: читаемый, широко используется (Ansible, GitHub Actions, mise тоже частично).

**Минусы**:
- Indentation-sensitive → трудно diff'ить, легко сломать пробелом.
- Безопасность: YAML 1.1 интерпретирует `yes`/`no` как bool, `2001-12-15` как дату → сюрпризы.
- Нет стабильной JSON Schema (draft-04 максимум, неполная поддержка anchors).
- Реализации в Go (gopkg.in/yaml.v3) — медленные, ~2× больше кода, чем TOML.

**Вердикт**: отвергнут из-за indentation trap и нестабильной семантики скаляров.

### JSON

**Плюсы**: schema first-class, парсеры в stdlib, ubiquitous.

**Минусы**:
- Нет комментариев (без JSON5/JSONC) → нельзя объяснить `WHY` рядом с `WHAT`.
- Многословный: `{"env": {"DATABASE_URL": "..."}}` vs `DATABASE_URL = "..."`.
- Нет многострочных строк без `\n` escape.
- Trailing comma запрещён.

**Вердикт**: отвергнут для primary формата; используем как один из `_.file` форматов.

### JSON5 / JSONC

**Плюсы**: комментарии, trailing comma.

**Минусы**:
- Нет стандарта JSON Schema.
- Редкие парсеры.
- Теряем tooling (большинство редакторов не подсвечивают).

**Вердикт**: отвергнут.

### HCL (HashiCorp)

**Плюсы**: мощный, как mini-DSL.

**Минусы**:
- HCL2 ещё не стабилен schema-wise, разные реализации ведут себя по-разному.
- Меньше tooling (vscode-hcl не super popular).
- Меньше людей умеют.

**Вердикт**: отвергнут, overkill.

### .env (dotenv)

**Плюсы**: уже используется повсеместно (`docker-compose`, Next.js, etc.), user-friendly.

**Минусы**:
- Нет типов (всё строка).
- Нет структур (`required`, `redact`).
- Нет вложенности.
- Нет массивов (нестандартные расширения).
- Нет JSON Schema.

**Вердикт**: используем как **один из** поддерживаемых форматов для `_.file`, но не как primary.

### KDL

**Плюсы**: structural, scheme-able, comments, mixed content.

**Минусы**:
- Свежий, мало кто знает.
- Tooling ещё не везде.
- Может перегружать для простого key-value.

**Вердикт**: отвергнут для MVP. Можем пересмотреть в v2.

## Почему TOML выигрывает

| Свойство | TOML | YAML | JSON | .env |
|---|---|---|---|---|
| Comments | ✅ | ✅ | ❌ | ✅ (через `#`) |
| Types | ✅ native | ✅ | ✅ | ❌ (всё string) |
| Arrays | ✅ first-class | ✅ | ✅ | ⚠️ нестандарт |
| Inline tables | ✅ | ✅ (flow) | ✅ (object) | ❌ |
| Multi-line strings | ✅ `"""..."""` | ✅ `\|` | ❌ (escape) | ❌ |
| Indentation-insensitive | ✅ | ❌ | ✅ | ✅ |
| Stable JSON Schema | ✅ 2020-12 | ⚠️ draft-04 | ✅ | ❌ |
| Diff-friendly | ✅ | ⚠️ | ⚠️ | ✅ |
| Editor support (LSP) | ✅ (taplo, even Better TOML) | ✅ | ✅ | ✅ |
| Go parser maturity | ✅ `BurntSushi/toml` (Go stdlib-style) | ⚠️ | ✅ stdlib | ✅ |
| Schema-first tooling | ✅ | ⚠️ | ✅ | ❌ |
| Time to learn | 10 min | 30 min | 0 min | 1 min |

**Toml конкретно для нашего use-case**:
- `DATABASE_URL = "postgres://..."` — коротко, видно глазом.
- `_.path = ["./bin", "{{config_root}}/node_modules/.bin"]` — массив inline.
- `API_KEY = { value = "default", required = true, redact = true }` — inline table для метаданных.
- `[profiles.dev]` — секции для профилей, естественно.
- `key = false` для unset (вместо хака `"key="`).

## Поддерживаемые форматы для `_.file`

- `.env` (dotenv) — для совместимости с существующими проектами.
- `.json` — для структурированных секретов, экспортированных из vault/1password.
- `.yaml` / `.yml` — если в проекте уже есть YAML.
- `.toml` — наш нативный.

## Schema

JSON Schema публикуется по адресу `https://envee.dev/schemas/envee-v1.json` (в MVP — bundled в репо: `docs/schema/envee-v1.json`).

IDE-плагины:
- VSCode: `redhat.vscode-yaml` + кастомный schema mapping.
- JetBrains: TOML plugin из коробки, schema mapping через `JSON Schema Mappings`.
- Vim/Neovim: `taplo` LSP.

## Пример полного `envee.toml`

```toml
schema = "envee/v1"
profile = "dev"

[env]
# Простые значения с типами
DATABASE_URL = "postgres://localhost/mydb"
PORT = 5432
DEBUG = true
TAGS = ["dev", "local"]

# Шаблоны (ADR-011)
LOG_PATH = "{{config_root}}/logs/{{profile}}.log"

# Structured value с метаданными
API_KEY = { value = "default-dev-key", required = false, redact = true }
DATABASE_POOL_SIZE = { value = 10, value_type = "int" }

# Unset (value=false)
LEGACY_FLAG = false

# Built-in directives
_.file = [
  ".env",
  { path = ".env.local", redact = true, required = false },
]
_.path = ["./node_modules/.bin", "{{config_root}}/bin"]

# Profile overlays
[profiles.dev]
DATABASE_URL = "postgres://localhost/mydb_dev"
LOG_LEVEL = "debug"

[profiles.prod]
DATABASE_URL = { value = "postgres://prod.example.com/mydb", required = true }
DATABASE_POOL_SIZE = 20
required = ["API_KEY", "DATABASE_URL", "DATABASE_POOL_SIZE"]
```

## Последствия

### Положительные

- `BurntSushi/toml` — Go-stdlib-style API, mature, fast.
- `taplo` — отличный LSP, schema-валидация в редакторе.
- Diff-friendly (line-oriented).
- Поддержка типов → `PORT = 5432` будет int, не string `"5432"`.
- User-friendly learning curve (cargo-стиль очень знаком).

### Отрицательные

- TOML не позволяет дублировать ключи в одной секции (нужно `[[env]]` array-of-tables для multiple `_.source`).
- Schema должна явно поддерживать `_.` как reserved namespace (мы это делаем).

### Нейтральные

- `envee import .envrc` — конвертер из bash .envrc в TOML (best-effort, не 100% покрытие).
