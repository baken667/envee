# ADR-011: Template Engine — минимальный Jinja-lite

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как вычислять значения env-переменных, зависящих от других переменных

## Контекст

Часто нужны derived values:
- `LOG_PATH = "{{config_root}}/logs/{{profile}}.log"`
- `LD_LIBRARY_PATH = "/some/path:{{env.LD_LIBRARY_PATH}}"`
- `REDIS_URL = "redis://{{env.REDIS_HOST}}:{{env.REDIS_PORT}}/0"`
- `K8S_NAMESPACE = "app-{{profile | lower}}"`

Сейчас direnv требует писать bash:
```bash
export LOG_PATH="$PWD/logs/dev.log"
```

Это **хрупко** (если `PWD` ещё не установлен), **непрозрачно** (не видно type).

## Решение

**Минимальный template engine** встроен в envee. Синтаксис: `{{ ... }}`.

### Поддерживаемые конструкции

**Variable access**:
- `{{config_root}}` — путь к корню envee.toml.
- `{{profile}}` — активный profile.
- `{{env.X}}` — переменная X из OS environment (или уже resolved env).
- `{{file.X}}` — значение из другого source (file-based).

**Filters** (через `|`):
- `{{name | upper}}` — uppercase.
- `{{name | lower}}` — lowercase.
- `{{name | trim}}` — strip whitespace.
- `{{name | default("fallback")}}` — fallback if empty.
- `{{path | abspath}}` — convert to absolute path.
- `{{path | realpath}}` — resolve symlinks, make absolute.
- `{{path | dirname}}` — directory of path.
- `{{path | basename}}` — filename of path.
- `{{value | quote}}` — shell-quote (single-quote, escape inner quotes).
- `{{value | quote_double}}` — double-quote with escape.
- `{{value | json}}` — JSON-encode.
- `{{value | base64}}` — base64-encode.

**Chains**:
- `{{path | realpath | abspath | quote}}`

**Conditionals** (в v1.x — minimal):
- `{{env.X | default(env.Y | default("fallback"))}}`

В v2.x — полные `{% if %} / {% for %}` (если спрос будет).

### Примеры

```toml
schema = "envee/v1"
profile = "dev"

[env]
# Базовые paths
CONFIG_DIR = "{{config_root}}/config"
LOG_PATH = "{{config_root}}/logs/{{profile}}.log"

# Defaults с fallback
REDIS_PORT = { value = "{{env.REDIS_PORT | default('6379')}}", value_type = "int" }

# Conditional (через default)
K8S_NAMESPACE = "{{profile}}-ns"  # "dev" → "dev-ns"
# Если нужна сложная логика:
K8S_NAMESPACE = """
{%- if profile == "prod" -%}production
{%- elif profile == "staging" -%}staging
{%- else -%}dev
{%- endif -%}
"""

# Computed path с абсолютизацией
DATA_DIR = "{{config_root}}/data | realpath"

# Reuse другой env var
DATABASE_URL = "postgres://{{env.DB_USER}}:{{env.DB_PASS}}@{{env.DB_HOST}}/{{env.DB_NAME}}"
```

### Где вычисляется

**В момент resolve**, не в момент загрузки TOML:

```
1. Load envee.toml → map of unresolved values (some are strings with {{ }}, some are concrete)
2. Build dependency graph: какие переменные от чего зависят
3. Topological sort
4. Evaluate в порядке зависимостей:
   - Concrete values — as-is
   - Template values — evaluate с substitution
5. Final env map
```

**Ошибки циклических зависимостей**:
```
[envee] ERROR: circular dependency detected:
  DATABASE_URL → env.DB_HOST → env.DATABASE_URL
[envee] HINT: simplify your template or use a constant value
```

### Sandbox

Template engine **не может**:
- ❌ Выполнять произвольный код (не Lua, не Python).
- ❌ Делать HTTP/file I/O.
- ❌ Spawn процессы.

**Может**:
- ✅ Читать уже resolved env variables.
- ✅ Path manipulation (realpath, dirname, etc.).
- ✅ String operations (upper, lower, trim, default).
- ✅ Encoding (base64, json, quote).

Если нужна сложная логика — `_.script` (WASM, per ADR-006).

## Реализация

### Custom parser (не Jinja2)

Почему **не** texttemplate/jinja2:
- Они тяжёлые (10-50K LOC).
- Сложнее аудитить (security: `{{exec("...")}}`).
- Overkill для нашего use case.

**Наш парсер** — 500 LOC Go, recursive descent:

```go
// internal/template/parser.go
type Node interface {
    Eval(ctx *Context) (string, error)
}

type LiteralNode struct{ Value string }
type VarNode struct{ Path string }      // "config_root", "env.X", "profile"
type FilterNode struct {
    Input Node
    Name  string
    Args  []Node
}
type ConcatNode struct{ Parts []Node }
```

### Lexer

```go
// internal/template/lexer.go
type tokenKind int
const (
    tText tokenKind = iota
    tOpenBraces  // {{
    tCloseBraces // }}
    tPipe        // |
    tDot         // .
    tIdent       // identifier
    tString      // "..."
    tInt         // 123
    tLParen      // (
    tRParen      // )
)

func tokenize(s string) ([]token, error) { ... }
```

### Evaluator

```go
// internal/template/eval.go
type Context struct {
    ConfigRoot string
    Profile    string
    Env        map[string]string  // already resolved
    OSEnv      map[string]string
}

func (n *VarNode) Eval(ctx *Context) (string, error) {
    switch {
    case n.Path == "config_root":
        return ctx.ConfigRoot, nil
    case n.Path == "profile":
        return ctx.Profile, nil
    case strings.HasPrefix(n.Path, "env."):
        key := strings.TrimPrefix(n.Path, "env.")
        if v, ok := ctx.Env[key]; ok { return v, nil }
        if v, ok := ctx.OSEnv[key]; ok { return v, nil }
        return "", fmt.Errorf("undefined env var: %s", key)
    }
    return "", fmt.Errorf("unknown variable: %s", n.Path)
}

func (n *FilterNode) Eval(ctx *Context) (string, error) {
    input, err := n.Input.Eval(ctx)
    if err != nil { return "", err }
    switch n.Name {
    case "upper": return strings.ToUpper(input), nil
    case "lower": return strings.ToLower(input), nil
    case "trim":  return strings.TrimSpace(input), nil
    case "default":
        if input != "" { return input, nil }
        if len(n.Args) == 0 { return "", nil }
        return n.Args[0].Eval(ctx)
    case "realpath":
        p, err := filepath.EvalSymlinks(input)
        if err != nil { return "", err }
        return p, nil
    case "abspath":
        return filepath.Abs(input)
    case "dirname":
        return filepath.Dir(input), nil
    case "basename":
        return filepath.Base(input), nil
    case "quote":
        return shellquote.Single(input)
    case "json":
        b, _ := json.Marshal(input)
        return string(b), nil
    case "base64":
        return base64.StdEncoding.EncodeToString([]byte(input)), nil
    }
    return "", fmt.Errorf("unknown filter: %s", n.Name)
}
```

### Dependency tracking

```go
// internal/template/deps.go
type Dependency struct {
    Var  string   // "DATABASE_URL"
    Refs []string // ["env.DB_USER", "env.DB_PASS", "config_root"]
}

func extractDeps(value string) []string {
    // Scan for {{...}} patterns, extract variable paths
    // Returns list like ["env.X", "profile", ...]
}
```

При resolve:
1. For each env var, compute `Refs` (from `{{...}}` в значении).
2. Build graph: var → depends on → list.
3. Topo sort. Если cycle → error.
4. Evaluate в topo order.

## Альтернативы

### Полный Jinja2 (`github.com/valyala/quicktemplate`, etc.)

**Плюсы**: знакомый синтаксис, мощный.

**Минусы**: 
- Большие зависимости (200K-1M LOC).
- Security: `{{exec(...)}}` через custom functions — must be disabled.
- Overkill.

**Вердикт**: отвергнут.

### text/template (Go stdlib)

**Плюсы**: stdlib, well-tested.

**Минусы**:
- `{{ .Env.X }}` синтаксис (с точкой, скобками) — не такой чистый.
- Нет pipe-фильтров из коробки (надо писать FuncMap).
- Нет условий в v1.x.

**Вердикт**: используем как fallback для v2.x (если наш парсер не справится), но primary — свой.

### Просто строковая интерполяция (`$X` как в bash)

**Плюсы**: очень просто, знакомо.

**Минусы**:
- Неотличимо от bash variables в строках.
- Нет фильтров.
- Нет default fallback.

**Вердикт**: слабый, не наш путь.

### Внешний шаблонизатор (sprig, helm)

**Плюсы**: мощно, battle-tested.

**Минусы**:
- Другие syntax (`{{ .Values.foo }}`).
- Тяжёлые зависимости.
- Helm templates — designed для K8s manifests, не env.

**Вердикт**: overkill.

## Безопасность

**Все template-выражения sandboxed**:
- Нет `exec`, `eval`, `import`.
- Нет filesystem access (кроме `realpath` который тоже не I/O, а stat).
- Нет сетевого доступа.
- Нет os env write.

**Validation в `envee check`**:
- Все `{{...}}` — parseable.
- Все referenced vars — defined (или explicit `default`).
- Никаких `import`/`exec`/`eval`-like patterns.

## Edge cases

### Рекурсия через env

```toml
A = "{{env.B}}"
B = "{{env.A}}"
```

→ cycle error.

### Self-reference

```toml
PATH = "{{env.PATH}}:/extra"
```

**Разрешается** через `env.PATH` (берётся из OS env до resolve, **не** из resolved env). Иначе — это self-reference.

**Правило**: `{{env.X}}` всегда смотрит на **OS env** или **pre-resolve** state, не на resolved (для избежания случайных override'ов).

### Multi-line

```toml
PRIVATE_KEY = """
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAK...
-----END RSA PRIVATE KEY-----
"""
```

TOML поддерживает multi-line strings (`"""..."""`). Envee не интерпретирует `{{` внутри `"""` если это явно raw string. Default — template active.

Чтобы отключить template:
```toml
PRIVATE_KEY = { value = '...{{ }}...', raw = true }
```

## Производительность

Template evaluation: ~0.1-0.5ms на переменную. Для 50 env vars = ~10-25ms cold. **OK** для нашего budget (10ms cold).

Cache: results кешируются в daemon (per ADR-008). Пересчёт только при изменении `envee.toml` или external env (через `$ENVEE_INVALIDATE` env var).

## v2.x roadmap

- `{% if cond %}{% else %}{% endif %}` — conditionals.
- `{% for x in list %}{% endfor %}` — loops.
- Custom filters (через plugins).
- `{% include "common.toml" %}` — file inclusion.

В v1.x — explicit "missing features", но use-cases закрываются через `_.script` (WASM).

## Последствия

### Положительные

- Знакомый `{{ ... }}` синтаксис (Jinja/Mustache/Handlebars style).
- Sandboxed by design.
- Dependency tracking → clear error messages.
- 500 LOC, easy to audit.
- Filters покрывают 80% use cases.

### Отрицательные

- Нет условий/циклов в v1.x → некоторые user'ы упрутся.
- Edge case: `{{env.X}}` resolution order — нужно документировать.
- Дополнительная поверхность для security review (хотя маленькая).

### Нейтральные

- Наш парсер vs `text/template` — если устанем поддерживать, можем мигрировать.
- Multi-line strings с `{{` внутри — нужно `raw = true`.
