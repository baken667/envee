# Envee → Zig: план переписывания и учебный маршрут

> **Исполняемый пошаговый план с чекбоксами и проверенными API 0.16 —
> в [zig-rewrite-steps.md](zig-rewrite-steps.md).** Этот файл — контекст и
> мотивация.
>
> Ветка: `feat/zig-rewrite`. Go-код остаётся в репозитории до конца порта и
> служит эталоном (reference implementation). Zig-код живёт рядом, в `src/`,
> и на каждом шаге сверяется с Go-бинарём через parity-тесты.

## 0. Целевая версия Zig

**Zig 0.16.x** (стабильный релиз апреля 2026). Это важно:

- В 0.15 полностью переписали `std.Io.Reader/Writer` («Writergate»).
- В 0.16 почти каждая I/O-операция (`fs`, `process.Child`, `File.writer`)
  принимает явный параметр `io: std.Io`. `main` получает `io` через
  `std.process` init.
- **Любой туториал, статья или ответ старше 2025 года будет врать в деталях.**
  Единственный надёжный источник: `zig std` (локальные доки стандартной
  библиотеки под установленную версию) и исходники `lib/std`.

Установка:

```bash
brew install zig zls
zig version          # ожидаем 0.16.x
zig std              # открывает доки std в браузере — держать открытыми всегда
```

Если brew даст не 0.16, брать архив с https://ziglang.org/download/ и
положить в `~/.local/zig/`; в `$PATH` должен быть ровно один `zig`.

Редактор: zls + `zig fmt` на сохранение. `zig build` при ошибке компиляции
показывает только первую ошибку в цепочке — это нормально, читать снизу
вверх по «referenced by».

## 1. Что именно переписываем (карта Go-кода)

Размер: ~13 000 строк Go, из них ~5 500 тесты. Пакеты в порядке
зависимостей (снизу вверх):

| Пакет | Строк | Что делает | Внешние зависимости в Go |
|---|---|---|---|
| `internal/env` | 200 | Упорядоченная map env-переменных, diff, merge | — |
| `internal/shell` | 680 + escape 150 | 5 адаптеров (bash/zsh/fish/nu/pwsh): hook-шаблоны, export/unset, escaping, fast-path | — |
| `internal/dotenv` | 350 | Парсер `.env`, ручной state machine | — |
| `internal/template` | 230 | Jinja-lite `{{ x \| filter }}`, детект циклов | — |
| `internal/paths` | 90 | XDG-пути | `adrg/xdg` |
| `internal/errs` | 200 | Ошибки с кодом E001…, hint, doc-ссылкой | — |
| `internal/log` | 110 | Логгер с редакцией секретов | — |
| `internal/config` | 560 | Схема `envee.toml`, парсинг, канонический hash | `BurntSushi/toml` |
| `internal/resolver` | 220 | Поиск `envee*.toml` вверх по дереву, merge | — |
| `internal/directive` | 480 + file 175 | Оркестратор: `_.file`, `_.path`, profile, secret, template | — |
| `internal/trust` | 340 + sign 160 + summary 200 + prompt 120 | Trust-store (JSON, sha256), ed25519-подписи, интерактивный prompt | `x/crypto/ssh` (парсинг OpenSSH-ключей) |
| `internal/plugin` | 240 + 210 + 90 | Поиск `envee-plugin-*`, exec + JSON-over-stdio, таймауты | — |
| `internal/cli` | ~2 300 | 18 команд | `spf13/cobra` |
| `internal/daemon` | 160 | UNIX-socket демон, **фактически заглушка** | — |
| `plugins/env` | 115 | Референсный плагин: локальное хранилище секретов | — |
| `pkg/sdk-go` | 205 | SDK для авторов плагинов | — |

Что **не** портируем:

- `internal/daemon` и `cmd/enveed` — не реализованы функционально. В Zig
  создаём stub-команду `daemon status`, которая честно отвечает «not running».
- `cmd/gen-docs` (man/completions через cobra) — заменяется тем, что
  генерирует наш CLI-парсер, в самом конце.
- `pkg/sdk-go` — остаётся на Go. Протокол плагинов exec+JSON языконезависим
  по дизайну (ADR-0007), Go-SDK продолжает работать с Zig-ядром.

Что появляется нового в Zig-версии:

- **Свой TOML-парсер** (подмножество TOML 1.0, которого хватает для
  `envee.toml`). Это самый большой кусок и лучшее упражнение.
- **Свой парсер аргументов** вместо cobra.
- **Парсер OpenSSH ed25519-ключей** (~80 строк, формат простой) вместо
  `x/crypto/ssh`.

## 2. Расположение файлов

```
envee/
├── build.zig            # новый
├── build.zig.zon        # новый (имя, версия, зависимости — пока пусто)
├── src/
│   ├── main.zig         # entry: парсит argv, зовёт cli
│   ├── env.zig          # ← internal/env
│   ├── shell/
│   │   ├── shell.zig    # Adapter как tagged union / vtable
│   │   ├── escape.zig
│   │   ├── bash.zig, zsh.zig, fish.zig, nu.zig, pwsh.zig
│   ├── dotenv.zig
│   ├── template.zig
│   ├── paths.zig
│   ├── errs.zig
│   ├── log.zig
│   ├── toml/            # свой парсер
│   │   ├── lexer.zig
│   │   ├── parser.zig
│   │   └── value.zig
│   ├── config.zig
│   ├── resolver.zig
│   ├── directive.zig
│   ├── trust/
│   │   ├── store.zig
│   │   ├── sign.zig
│   │   ├── ssh_key.zig
│   │   └── summary.zig
│   ├── plugin.zig
│   └── cli/
│       ├── args.zig     # свой парсер флагов
│       ├── root.zig
│       └── <command>.zig
├── scripts/
│   └── parity.sh        # Go vs Zig на examples/
└── internal/…           # Go, не трогаем до фазы 12
```

Go и Zig не мешают друг другу: `go build ./...` не видит `src/`, `zig build`
не видит `internal/`.

## 3. Правила порта

1. **Go — эталон поведения, не структуры.** Не переносить интерфейсы 1:1.
   В Zig нет методов на интерфейсах в Go-смысле; для адаптеров shell —
   `union(enum)` + `switch`, для plugin resolver — struct с указателями на
   функции (vtable) или `anytype` в comptime-generic.
2. **Один аллокатор на запуск CLI.** `envee eval` живёт миллисекунды: в
   `main` создаём `std.heap.ArenaAllocator` поверх `page_allocator` и
   отдаём его всему дереву вызовов. Ничего не освобождаем. В тестах —
   `std.testing.allocator` (ловит утечки) — это заставит написать
   `deinit` там, где он нужен, что полезно для обучения, но в проде arena.
3. **Ошибки.** Go-пакет `errs` с кодами E001… переносится как:
   `error{TrustRequired, ConfigParse, …}` + отдельный «diagnostic»
   контекст (struct с code/summary/hint/context), который кладётся в
   thread-local / передаётся через `*Diag` параметр. Exit-код считается из
   error set тем же маппингом, что `cli.ExitCode` в Go.
4. **Каждый портированный модуль = тесты портированы.** Go-тесты — это
   спецификация. Табличные тесты (`[]struct{in, want}`) переносятся в Zig
   как `const cases = [_]struct{ in: []const u8, want: []const u8 }{…}` и
   цикл с `std.testing.expectEqualStrings`.
5. **Parity перед следующей фазой.** Пока `scripts/parity.sh` не зелёный
   для того, что уже реализовано, дальше не идём.
6. **Никакого `cgo`-аналога.** Только `std`. Единственная возможная
   зависимость — TOML-парсер, и то только если свой окажется непосилен
   (см. фазу 6).
7. Коммиты по фазам: `zig(env): port Map and diff`, `zig(shell): …`.
   CHANGELOG не трогаем до релиза.

## 4. Фазы

Каждая фаза: **что порт** → **что учим в Zig** → **критерий готовности**.
Оценки времени — при 1–2 часах в день.

### Фаза 0 — Skeleton и первое «hello» (1 вечер)

Порт: ничего. Создать `build.zig`, `build.zig.zon`, `src/main.zig`,
`scripts/parity.sh`.

Учим: `zig init`, анатомия `build.zig` (`b.addExecutable`, `b.addTest`,
`b.installArtifact`, `b.step("test")`), `zig build run -- args`, `zig build
test`, `zig fmt`.

Минимальный `main.zig` для 0.16.0 (сверено с `zig init` и
`lib/std/process.zig` установленной версии):

```zig
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    // init.arena — готовая арена на весь процесс, освобождается сама.
    // init.gpa   — general-purpose аллокатор (в Debug ловит утечки).
    // init.io    — обязателен для любого I/O в 0.16.
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    try out.print("envee-zig argc={d}\n", .{args.len});
}
```

Что здесь новое относительно старых туториалов: `std.io.getStdOut()`
больше нет, `ArrayList` по умолчанию unmanaged (`var l: std.ArrayList(u8) =
.empty; try l.append(gpa, x); l.deinit(gpa)`), `std.debug.print` пишет в
stderr без буфера и `io` не требует. Если что-то не компилируется, ответ
искать в `zig std` и в `lib/std/` (`zig env` показывает `lib_dir`), а не в
интернете.

`zig init` генерирует рабочий шаблон с `root.zig` (библиотечный модуль) +
`main.zig` (exe) и fuzz-тестом — можно выполнить его в scratch-каталоге и
переписать `build.zig` под себя, выкинув комментарии.

`build.zig` цели: `envee` (exe), `test` (все `test` блоки из `src/`),
опционально `-Dversion=` для впечатывания версии (замена `-ldflags -X`).

Готово: `zig build && ./zig-out/bin/envee` печатает строку; `zig build test`
проходит с одним тривиальным `test "smoke" {}`.

### Фаза 1 — `env.zig` (2–3 вечера)

Порт: `internal/env/env.go` + `env_test.go`. `Map` — упорядоченная по
ключу коллекция `Entry{key, value, redacted, source}`; `Set/Get/Unset/
Keys/Diff/Merge/Clone`.

Учим: структуры, `std.ArrayList`, `std.StringHashMap`, срезы vs массивы,
`[]const u8` как строка, `std.mem.eql`, `std.sort`, владение памятью
(кто `dupe`-ит строку — вызывающий или Map), `defer/errdefer`,
`std.testing`.

Совет: держать entries в `ArrayList(Entry)` отсортированным по ключу и
искать бинарным поиском — index-map не нужен, ключей десятки.

Готово: все кейсы из `env_test.go` зелёные под `std.testing.allocator`
(без утечек).

### Фаза 2 — `shell/` (4–6 вечеров)

Порт: `escape.go`, `shell.go` (5 адаптеров), `fastpath`. Это горячий путь,
ради которого ADR-0001 и допускал переписывание.

Учим: `union(enum)` для `Adapter`, `switch` с исчерпывающим перебором,
`std.Io.Writer` (писать сразу в writer, а не собирать строки),
многострочные литералы `\\`, comptime-константы, `std.fmt.format`
placeholder-подстановка (`{{.SelfPath}}`), байтовая итерация по строке.

Ключевые детали, которые легко потерять:

- `BashEscape`: три режима — пусто → `''`; только безопасные символы →
  как есть; control/non-ASCII → `$'…'` ANSI-C; иначе single-quote с `'\''`.
  Набор безопасных: `[A-Za-z0-9./-_:=,+@%]`.
- Fish-escaping отличается от bash (см. `FishAdapter.Escape`).
- Nu получает не команды, а JSON для `load-env` (`DiffRenderer`).
- Fast-path (`FastPathRenderer`): после diff hook получает список
  зависимостей (`__envee_deps`) и stamp-файл; это то, что даёт «0 ms на
  prompt». Hook-шаблоны переносим **байт в байт**, они протестированы на
  живых shell.

Тесты: `shell_test.go`, `hooks_test.go` → обычные. `escape_roundtrip_test.go`
и `hook_exec_test.go` запускают настоящие bash/zsh/fish — переносить через
`std.process.Child` (это заодно подготовка к фазе 10).

Готово: `zig build test` зелёный; `./zig-out/bin/envee init bash` побайтно
совпадает с `./bin/envee init bash` (первая строка в `parity.sh`).

### Фаза 3 — `dotenv.zig` (2 вечера)

Порт: `parse.go` state machine + `parse_test.go` (282 строки тестов —
хорошая спецификация).

Учим: `enum` для состояний, `while` с индексом по срезу, `switch` на
байтах с диапазонами `'a'...'z'`, error sets с полезными именами
(`error.UnterminatedQuote`), `std.StringHashMap([]const u8)`.

Готово: тесты зелёные.

### Фаза 4 — `template.zig` (2–3 вечера)

Порт: `template.go` (`{{ expr | filter(arg) }}`, фильтры upper/lower/trim/
default/abspath/dirname/basename/quote/json/base64), детект циклов при
подстановке `{{env.X}}`.

Учим: `std.mem.indexOf`, `std.mem.tokenizeScalar`, `std.fs.path`,
`std.base64`, `std.json.Stringify`, простая рекурсия с visited-set.

Готово: тесты зелёные.

### Фаза 5 — `paths.zig`, `errs.zig`, `log.zig` (1–2 вечера)

Порт: XDG-логика (`adrg/xdg` заменяется на чтение `XDG_*` переменных с
дефолтами). **Дефолты на macOS отличаются от Linux** (проверено в
`adrg/xdg@v0.5.3/paths_darwin.go`): без переменных `ConfigHome`,
`DataHome` и `RuntimeDir` все равны `~/Library/Application Support`,
`CacheHome` = `~/Library/Caches`. Zig-версия обязана повторить это, иначе
trust-store и `secrets/env.json` «потеряются» при переходе с Go на Zig.
(README сейчас пишет `~/.local/share/envee/…` — это верно только для Linux.)
`errs` — см. правило 3. `log` — уровни + редакция значений по ключу.

Учим: `std.process.getEnvVarOwned` / `std.posix.getenv`, `std.fs.path.join`,
`std.fs.cwd().makePath`, форматирование в stderr, `comptime` enum для
уровней.

Готово: `paths_test.go`, `redact_test.go` зелёные.

### Фаза 6 — TOML-парсер (1–2 недели, главный boss)

Порт: заменить `BurntSushi/toml`. Нужное подмножество (ровно то, что
встречается в `examples/` и тестах `config`):

- строки basic (`"…"` с escape) и literal (`'…'`), **не** нужны multi-line
  на первом проходе (добавить, если тесты потребуют)
- integer, boolean, массивы (в т.ч. смешанные — `_.file` это массив
  таблиц-inline)
- inline tables `{ value = "x", redact = true }`
- таблицы `[env]`, вложенные `[profiles.dev.env]`, dotted keys `_.path = …`
- комментарии, пустые строки
- номера строк в ошибках (в Go был TODO — сделать лучше)

Не нужно: даты, floats (пока), arrays of tables `[[x]]`.

Архитектура: `lexer.zig` (токены с позицией) → `parser.zig` → `value.zig`
(`union(enum){ string, int, bool, array, table }`, table = упорядоченная
`StringArrayHashMap` — порядок нужен для канонического хеша).

**Канонический хеш.** В Go: sha256 от re-marshal'а через BurntSushi с его
порядком ключей. **Это нельзя воспроизвести байт-в-байт без BurntSushi**, а
значит существующие trust-записи станут невалидными при смене бинаря.
Решение: определить собственный канонический формат (отсортированные
ключи, фиксированный формат значений) и версионировать trust-entry
(`version: 2`). Пользователю при первом запуске один раз потребуется
`envee trust` заново — приемлемо для pre-1.0. Записать это как ADR-0019.

Учим: tagged unions с payload, рекурсивные типы через указатели,
`std.StringArrayHashMap`, `std.fmt.parseInt`, `std.unicode` для `\u`
escape, `std.crypto.hash.sha2.Sha256`, написание fuzz-теста (`zig build
test --fuzz` — есть в 0.14+, проверить в 0.16).

Fallback: если после недели парсер не тянет — подключить
`sam701/zig-toml` или `mattyhall/tomlz` через `zig fetch --save`; научиться
`build.zig.zon` зависимостям. Но свой парсер стоит попытаться.

Готово: `config/parse_test.go`, `directives_test.go` зелёные; все
`examples/*/envee.toml` парсятся.

### Фаза 7 — `config.zig` + `resolver.zig` (3–4 вечера)

Порт: типы `Config/Profile/Directives/FileRef/…`, пост-обработка (`env._`
→ directives, flatten `[profiles.X]`, `watch`), `SecretRefs()`; resolver —
подъём по дереву, `envee.d/*.toml`, `stop_search_up`, `MergeInto`.

Учим: `std.fs.Dir.iterate`, `std.fs.Dir.stat`, `std.fs.path.dirname`,
обработка `error.FileNotFound`, `std.fs.realpath`, оптионалы `?T` и
`orelse`.

Готово: `resolver_test.go` зелёный; `envee resolve --json` (после фазы 9)
совпадает с Go на examples.

### Фаза 8 — `directive.zig` (3–4 вечера)

Порт: `Apply` — порядок наложения (`_.file` → profile → `[env]`),
`_.path` prepend/append, `required`, `redact`, топологический порядок
templates, `PrependToPath`, `file.go` (dotenv/json/yaml/toml loaders — yaml
**не** портируем, вернуть понятную ошибку «yaml not supported»; проверить,
есть ли yaml в тестах).

Учим: composition нескольких модулей, интерфейс `PluginResolver` как
struct-с-указателями-на-функции, `std.json.parseFromSlice` для `_.file`
json.

Готово: `directive_test.go` зелёный.

### Фаза 9 — CLI: `args.zig`, `root`, `eval`, `resolve`, `init`, `check` (1 неделя)

Порт: cobra → свой парсер: persistent flags (`--config --profile
--log-level --log-format --color -q -v --debug`), подкоманды, `--help`,
`--version`, exit-коды по `ExitCode`. Сначала только 4 команды, чтобы
получить работающий `eval` end-to-end.

Учим: `std.process.args`, `std.Io.File.stdout().writer(io, buf)`, exit
через `std.process.exit`, обработка ошибок на верхнем уровне (`catch |e|
switch (e)`), `std.builtin` для версии из `build.zig` (`b.addOptions()`).

Готово: **главная веха** — `eval "$(./zig-out/bin/envee eval zsh)"` в
`examples/basic` работает, `parity.sh` сравнивает `eval bash|zsh|fish|nu|
pwsh`, `resolve --json`, `init <shell>`, `check` для всех examples.
С этого момента можно **жить на Zig-бинаре** (подменить в `~/.zshrc`).

### Фаза 10 — `trust/` (1 неделя)

Порт: store (JSON entry, sha256, `0600`, expiry, deny по пути),
интерактивный prompt (`[Y/n/d/s/q]` + diff), summary; `sign.zig` — ed25519
(`std.crypto.sign.Ed25519`), `ssh_key.zig` — парсер OpenSSH private/public
key (формат: `openssh-key-v1`, base64, без passphrase; с passphrase —
ошибка с подсказкой).

Учим: `std.json` (parse в struct с `std.json.parseFromSlice(Entry, …)` и
`std.json.Stringify`), `std.fs.File.setPermissions` / `createFile(.{.mode =
0o600})`, `std.crypto`, чтение stdin построчно, атомарная запись файла
(tmp + rename).

Готово: `store_test.go`, `sign_test.go`, `summary_test.go`,
`trust_share_test.go` зелёные. `envee trust / deny / status --trust /
trust --sign / trust --from`.

### Фаза 11 — `plugin.zig` + `plugins/env` на Zig (4–5 вечеров)

Порт: discovery (`envee-plugin-*` в PATH и в `$XDG_DATA_HOME/envee/
plugins`), `metadata` / `resolve` через `std.process.Child` с stdin-pipe,
таймауты 5s/10s, разбор error-response, `secret set/unset/list/get`.
Референсный плагин `envee-plugin-env` — **тоже на Zig** (второй exe в
`build.zig`): это проверит, что протокол реально языконезависим.

Учим: `std.process.Child` (spawn, `stdin_behavior = .Pipe`, `collectOutput`,
`wait`, kill по таймауту через `std.Io` timers / отдельный поток),
`std.Thread` если нужен watchdog, `std.json` глубже.

Готово: `exec_test.go` (309 строк — таймауты, плохие exit-коды, мусор в
stdout) зелёный; `pkg/sdk-go/testdata/demoplugin` (Go) работает с
Zig-ядром — это доказательство совместимости.

### Фаза 12 — остальные команды, CI, релиз (1 неделя)

- `status`, `diff`, `exec`, `doctor`, `plugin list/info`, `daemon status`
  (stub), `version`, `completion` (генерировать из описания команд).
- Скрытые «not implemented» команды — оставить с exit 1, как в Go.
- `build.zig`: cross-compile матрица `-Dtarget=x86_64-linux-musl,
  aarch64-linux-musl, x86_64-macos, aarch64-macos, x86_64-windows`
  (`ReleaseSafe`, `strip = true`). Zig делает это без goreleaser.
- CI: `mlugg/setup-zig` в GitHub Actions, матрица ОС для тестов с живыми
  shell (уже стоят fish/zsh в текущем workflow).
- Релиз: goreleaser не нужен; архивы + checksums + minisign/cosign в
  workflow. Обновить `homebrew-tap/Formula/envee.rb` (Homebrew умеет
  `depends_on "zig" => :build` либо брать prebuilt-архив).
- Docs: ADR-0001 → Superseded by ADR-0019 «Language: Zig» (написать честно,
  что мотивация — обучение + hot path, и что потеряли: cobra, goreleaser,
  x/crypto/ssh).
- Удалить `internal/`, `cmd/`, `go.mod`, `.golangci.yml`, `.goreleaser*`.
  `pkg/sdk-go` вынести в отдельный репозиторий либо оставить с отдельным
  `go.mod`.

Готово: `make`-цели заменены на `zig build` шаги, CI зелёный на трёх ОС,
`parity.sh` убран (эталона больше нет), CHANGELOG получает запись о
переходе и о необходимости re-trust.

## 5. `scripts/parity.sh`

Скелет; наращивать по мере фаз:

```bash
#!/usr/bin/env bash
set -euo pipefail
GO=./bin/envee
ZIG=./zig-out/bin/envee
make build >/dev/null && zig build

check() {  # check <name> <cmd...>
  local name=$1; shift
  if diff <(env -i HOME="$HOME" PATH="$PATH" "$GO" "$@" 2>&1) \
          <(env -i HOME="$HOME" PATH="$PATH" "$ZIG" "$@" 2>&1); then
    echo "ok   $name"
  else
    echo "FAIL $name"; exit 1
  fi
}

for sh in bash zsh fish nu pwsh; do
  check "init $sh" init "$sh"
done
# фаза 9+:
# for ex in examples/*/; do
#   (cd "$ex" && for sh in bash zsh fish; do check "eval $sh $ex" eval "$sh"; done)
# done
```

Учесть: `init` содержит абсолютный путь к бинарю — либо нормализовать
`sed`, либо сравнивать после подстановки `{{.SelfPath}}`.

## 6. Учебные материалы (под 0.16)

Порядок чтения:

1. **Ziglings** — https://codeberg.org/ziglings/exercises. 100+ маленьких
   упражнений «почини компиляцию». Пройти первые ~60 до фазы 1, остальные
   параллельно. Это быстрее любой книги.
2. **Language Reference** для установленной версии —
   https://ziglang.org/documentation/0.16.0/. Читать выборочно по мере
   надобности: comptime, error sets, optionals, slices, unions.
3. **`zig std`** — доки стандартной библиотеки. Единственный источник
   правды по API.
4. **Release notes 0.15 и 0.16** — чтобы понимать, почему код в интернете
   не компилируется: https://ziglang.org/download/0.16.0/release-notes.html
5. **zig.guide** (бывший ziglearn) — только главы про build system и
   аллокаторы; остальное частично устарело.
6. Исходники `lib/std/json`, `lib/std/zon` — образец того, как в Zig
   пишут парсеры (пригодится для фазы 6).
7. Для вопросов — Ziggit (https://ziggit.dev), там отвечают под текущую
   версию.

Ментальные переходы Go → Zig, на которых обычно спотыкаются:

| Go | Zig |
|---|---|
| GC, `make`, `append` | Явный `allocator`; `ArrayList` unmanaged: `.empty`, `append(alloc, x)`, `deinit(alloc)`; кто выделил — тот освобождает |
| `string` | `[]const u8`, без гарантии `\0`, без UTF-8 гарантии |
| `interface` | `union(enum)` + `switch` или vtable-struct; `anytype` для comptime-duck-typing |
| `err != nil` | `try` / `catch` / error union `!T`; ошибки — enum без payload |
| `nil` | `?T` + `orelse`, `null` только у optional |
| `defer` (на функцию) | `defer` (на блок) + `errdefer` |
| `map[string]T` | `std.StringHashMap(T)`; порядок — `StringArrayHashMap` |
| `fmt.Sprintf` | `std.fmt.allocPrint(alloc, …)` или писать в `Writer` |
| goroutine | `std.Thread` / `std.Io` async (в 0.16 ещё меняется — не строить на этом) |
| `os/exec` | `std.process.Child` |
| `encoding/json` | `std.json` (parse в struct через reflection в comptime) |
| табличный тест | `inline for` по comptime-массиву кейсов или обычный `for` |

## 7. Чек-лист перед каждым коммитом

```bash
zig fmt --check src/
zig build test
./scripts/parity.sh
```

## 8. Открытые решения (принимать по ходу, записывать как ADR)

- ADR-0019 Language Zig (supersedes 0001).
- ADR-0020 Canonical hash v2 и миграция trust-store.
- TOML: свой парсер vs зависимость — решить в конце фазы 6.
- Судьба `pkg/sdk-go`: отдельный репо или оставить.
- Windows: Zig компилирует под windows легко, но hook-и pwsh и paths
  нужно прогнать на реальной машине; до этого — «best effort».
