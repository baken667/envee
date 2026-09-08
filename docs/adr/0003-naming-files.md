# ADR-003: Имена файлов и поисковая семантика

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как называть файлы конфига, как их искать, иерархия override'ов

## Контекст

Нужна понятная иерархия конфигов, которая:
- Совместима с mental model direnv (есть корневой файл, его можно переопределить).
- Поддерживает personal overrides (коммитится vs нет).
- Не конфликтует с `.env*` (это для runtime приложения).
- Работает в монорепо (разные `envee.toml` на разных уровнях).
- Позволяет shared fragments (`envee.d/*.toml`).

## Решение

### Primary config: `envee.toml`

Без точки в начале — это **наш** файл, явно принадлежит инструменту. Не путается с `.envrc` (это direnv) или `.env` (это для приложения).

### Personal override: `envee.local.toml`

Стандартный паттерн (next.js, многие Go-проекты): `*.local.toml` — это файл, который нужно добавить в `.gitignore`. По умолчанию envee в `init` создаёт пример `.gitignore`-сниппета.

### Profile-specific: `envee.<profile>.toml` / `envee.local.<profile>.toml`

Альтернативный синтаксис для профилей через отдельные файлы (вместо `[profiles.dev]` внутри одного файла). Когда профиль сложный и раздутый — выносится.

### Shared fragments: `envee.d/*.toml`

Аналог `conf.d/` в systemd/mise. Все не-скрытые `.toml` файлы в этой директории загружаются в алфавитном порядке. Полезно для:
- Монорепо: `envee.d/30-backend.toml`, `envee.d/40-frontend.toml` для двух команд.
- Темплейтов: `envee.d/10-aws.toml`, `envee.d/20-k8s.toml` (через `include`).

### Global defaults: `~/.config/envee/config.toml`

Стандартный XDG-путь. Грузится самым нижним приоритетом.

## Иерархия поиска (от высокого приоритета к низкому)

```
<cwd>/envee.local.toml                 # личное, гитигнорится
<cwd>/envee.toml                       # проект, коммитится
<cwd>/envee.d/*.toml                   # фрагменты, коммитятся
<parent>/envee.local.toml              # личное на уровень выше (если cwd в сабпроекте)
<parent>/envee.toml
<parent>/envee.d/*.toml
... (вверх до git root или filesystem root)
~/.config/envee/config.toml            # глобальные дефолты
```

**Merge-семантика** (для каждого ключа):
- Child > Parent > Grandparent > ... > Global.
- **Для scalars**: последний wins.
- **Для maps**: recursive merge (keys объединяются).
- **Для arrays**: **replace** (не concat) — иначе нельзя переопределить `_.path = ["./a", "./b"]` без копирования всего массива.
- **Профили**: `[profiles.X]` мерджатся как обычные секции, profile selection — на финальном этапе (см. ADR-010).

## Что НЕ используем как имена

- `.envrc` — занято direnv, пользователь уже знает.
- `.envoir` — с конфликтами с `.envrc`-tools, плохо расширяется.
- `.env.toml` — конфликтует с `dotenv`-tools, которые читают `.env*` как свой формат.
- `env.toml` (без dot) — некоторые tool'ы (asdf) уже используют для своих целей.

## Edge cases

### Файл из чужого инструмента

Если `envee` встречает `.envrc` (но не `envee.toml`), он **молча игнорирует** — не пытается его читать, не warning'ит. Если хочется мигрировать — `envee import .envrc` явно.

### Монорепо с вложенными проектами

```
monorepo/
├── envee.toml                # common: K8S_NAMESPACE, MONOREPO_ROOT
├── services/
│   ├── api/
│   │   ├── envee.local.toml  # local API_PORT
│   │   ├── envee.toml        # API_DATABASE_URL
│   │   └── envee.d/10-redis.toml
│   └── web/
│       └── envee.toml
```

Когда user в `services/api/`, загружаются:
1. `services/api/envee.local.toml` (high)
2. `services/api/envee.toml`
3. `services/api/envee.d/10-redis.toml`
4. `monorepo/envee.toml` (low, parent)
5. `~/.config/envee/config.toml` (global)

### Workspace marker

В монорепо можно явно остановить поиск вверх, создав `envee.toml` со `stop_search_up = true`:

```toml
schema = "envee/v1"
stop_search_up = true
```

Это предотвращает загрузку parent envee.toml'ов. Полезно когда вложенный проект хочет **полностью изолированный** env.

### Trusted dir markers

Директория `envee.lock` (опционально) — lockfile с резолвнутым hash'ем всех загруженных файлов, для reproducibility. **v1.x**: опциональный, не блокирует. **v2.x**: можем сделать блокирующим для CI.

## Совместимость с .envrc (миграция)

`envee import .envrc [path]` — команда, которая:
1. Парсит bash-логику `.envrc` (AST-lite, не полный bash).
2. Извлекает `export X=Y` → TOML `X = "Y"`.
3. Извлекает `PATH_add X` → TOML `_.path = [..., "X"]`.
4. Извлекает `dotenv` → TOML `_.file`.
5. Извлекает `use node`/`use python` → TOML `_.tool` (если встроенная поддержка, иначе warning).
6. Сложные bash-конструкции (loops, conditionals) → wrapping в `_.script` с пометкой `# MANUAL REVIEW NEEDED`.

Не пытаемся быть 100% конвертером. Цель — **80% common cases за 0 секунд**, остальное — explicit `_.script` блок.

## Поиск файлов — реализация

`internal/resolver/discovery.go`:

```go
type Resolver struct {
    cwd         string
    fsRoot      string         // os.Stat("/")
    gitRoot     string         // optional, from `git rev-parse --show-toplevel`
    xdgConfig   string         // $XDG_CONFIG_HOME/envee
}

// Resolve returns all config files in priority order (high → low).
// Skips files that don't exist. Returns absolute paths.
func (r *Resolver) Resolve() ([]File, error)
```

Алгоритм:
1. `r.cwd` → check existence каждого из `envee.local.toml`, `envee.toml`, `envee.d/*.toml`.
2. Parent dir = `filepath.Dir(r.cwd)`. Repeat until parent == r.gitRoot (если есть) или `r.fsRoot`.
3. Добавить `r.xdgConfig` файлы.

Кешируется через daemon (inotify invalidation), см. ADR-008.

## Последствия

### Положительные

- Понятная иерархия, предсказуемые override'ы.
- Совместимость с mental model direnv + улучшения (профили, фрагменты, local).
- Не конфликтует с `.env*` для runtime.
- Простая миграция: `envee import .envrc` + коммит нового `envee.toml`.

### Отрицательные

- Нужно документировать **разницу между child и parent** merge (новички будут удивляться «почему у меня две `DATABASE_URL`?»).
- `envee.d/*.toml` — алфавитный порядок значит, что `10-foo` ломается на `9-bar` (lexicographic, не numeric). Нужно явно сказать в доках: `10-`, `20-`, `30-` (не `1-`, `2-`).

### Нейтральные

- Lockfile (`envee.lock`) в v1.x — не критично, но architecturally заложено.
