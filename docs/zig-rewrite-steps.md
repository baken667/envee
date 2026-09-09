# Zig rewrite — пошаговый план реализации

> Исполняемый план. Высокоуровневая мотивация и фазы — в
> [zig-rewrite.md](zig-rewrite.md); этот файл — конкретные шаги для
> исполнителя (человека или модели). Шаги идут строго по порядку, каждый
> заканчивается зелёными тестами и коммитом.

## Как пользоваться этим планом

1. Прочитать разделы «Текущее состояние», «Окружение» и «Правила» целиком.
2. Взять первый незакрытый шаг. Перед реализацией **прочитать Go-эталон**,
   указанный в шаге, целиком, включая `_test.go`: Go-тесты — это
   спецификация, их кейсы переносятся в Zig-тесты.
3. Реализовать, прогнать `zig fmt src build.zig && zig build test --summary all`,
   при наличии — `./scripts/parity.sh`.
4. Закоммитить с указанным сообщением. Отметить шаг в разделе «Текущее
   состояние» (заменить `[ ]` на `[x]`, дата).
5. Go-код **не трогать** до шага 23. Если в Go найден баг — записать в
   раздел «Найдено в Go» внизу, в Zig реализовать правильное поведение и
   покрыть тестом.

## Текущее состояние

Обновлять при закрытии шага.

- [x] Шаг 0 — skeleton (`build.zig`, `build.zig.zon`, `src/main.zig`), коммит `9eb50ef`. 2026-09-09
- [x] Шаг 1 — `env.zig`: `Entry`, `Map` (len/get/getEntry/set/setEntry/unset/keys/clone/merge/asExport/fromEnviron), `diff`; 12 тестов. Коммит `d6738eb`. 2026-09-09
- [x] Шаг 2 — `shell/escape.zig`: bash/singleQuote/ansiC/doubleQuote/fish/nu/pwsh, writer-API + alloc-обёртки; 13 тестов, из них round-trip на живых bash/zsh/fish. Вывод сверен с Go побайтно (31 значение × 6 функций, 0 расхождений). Коммит `e903577`. 2026-09-09
- [x] Шаг 3 — `shell/shell.zig` (Adapter как enum с методами: detect/writeInit/writeEscaped/writeExport/writeUnset/writeSetPath/writeDiff/writeFastPath), `shell/hooks/*.zig` (5 шаблонов, сгенерированы из Go-дампа), `shell/hook_test.zig` (6 живых тестов fast path на bash/zsh/fish). 42 теста. Вывод сверен с Go побайтно: 5 шаблонов init + 1105 байт adapter-операций, 0 расхождений. Коммит `14e9c7d`. 2026-09-09
- [x] Шаг 4 — `scripts/parity.sh` + временный exe `envee-dev` (`src/dev_main.zig`, удалить на шаге 15). Сверяет `init` для 5 оболочек, 5/5 ok; проверено, что на подложенном расхождении падает с кодом 1. Коммит `0fb4f35`. 2026-09-09
- [x] Шаг 5 — `dotenv.zig`: конечный автомат, `Vars` (владеет ключами и значениями), `parse`/`parseWithExpansion`/`parseFile`, `Diagnostics` с номером строки. 62 теста. Сверено с Go на 44 входах (включая CRLF, `export` не в первой строке, 3 ошибочных) — 0 расхождений. Коммит `94318bc`. 2026-09-09
- [x] Шаг 6 — `template.zig`: `render`, `extractVarRefs`, 9 фильтров, POSIX-семантика путей как в Go (`clean`/`dirname`/`basename`/`absPath`). 71 тест. Сверено с Go на 49 шаблонах (9 из них ошибочные) — 0 расхождений. Коммит `b2d060e`. 2026-09-09
- [x] Шаг 7 — `paths.zig`: `Paths.init`/`deinit`/`ensureDirs`, дефолты macOS/Linux/Windows как в `adrg/xdg@v0.5.3`, отбрасывание относительных XDG_*, раскрытие `~` и `$HOME`, runtime-каталог с правами 0700. 79 тестов. Сверено с Go на 6 конфигурациях окружения (48 путей) — 0 расхождений. Коммит `c64fc92`. 2026-09-09
- [x] Шаг 8 — `errs.zig` (Code E001–E015 с exitCode и doc-URL, `Diag` с рендерингом как в Go, `fail`/`take`, 6 конструкторов) и `log.zig` (уровни, text/json, quiet, редакция секретов независимо от типа значения и внутри групп). 98 тестов. Рендеринг ошибок сверен с Go: 9 ошибок + 15 doc-URL, 0 расхождений. Коммит `2ddd69f`. 2026-09-09
- [x] Шаг 9 — `toml/lexer.zig`: токены с позицией (строка+столбец), строки всех четырёх видов, числа во всех системах счисления, отказ от дат с указанием места. 113 тестов, включая лексирование всех 5 реальных `examples/**/*.toml` с диска. Коммит `9772cd2`. 2026-09-09
  - **Решение:** `true`/`false`/`inf`/`nan` лексер отдаёт как `bare_key` — по спецификации TOML это ещё и допустимые имена ключей. Различать значение и ключ будет парсер (шаг 10), у него есть контекст.
  - **Ограничение:** ключ, начинающийся с цифры (спецификация это разрешает), будет разобран как число. В `envee.toml` таких нет.
- [x] Шаг 10 — `toml/value.zig` (дерево, каноническое представление, `canonicalHash`) и `toml/parser.zig` (заголовки таблиц, массивы таблиц, составные ключи, inline-таблицы, массивы, все виды строк и чисел, ошибки с позицией). 141 тест. **Своя реализация, зависимость не понадобилась.** Логическое содержимое сверено с BurntSushi на 29 документах (5 реальных примеров + 24 синтетических) — 0 расхождений. Коммит `f04f9d3`. 2026-09-09
  - **Формат канонического вида:** плоские строки `"a"."b" = значение`, отсортированные; ключи и строки в кавычках JSON. Это НЕ валидный TOML, а вход для хеш-функции. Отсюда следует пункт про `version: 2` в шаге 17.
  - **Отступление от плана:** идемпотентность `parse(canonical(x)) == x` не проверяется, потому что канонический вид намеренно не TOML. Вместо неё проверено то, ради чего хеш существует: форматирование, комментарии, стиль кавычек, порядок ключей и CRLF хеш не меняют, а любое смысловое отличие — меняет.
  - Golden-хеш в тесте посчитан независимо (`shasum`), а не тем же кодом.
- [x] Шаг 11 — `config.zig`: типы схемы, `parseBytes`/`parseFile`, лифт `env._`→директивы и `watch`→`watched_paths`, профили (вложенные и inline-ключи), `secretRefs` для обеих записей, `sortedKeys`. 159 тестов. Схема сверена с Go на 22 конфигах (5 реальных + 17 синтетических): все поля, все виды директив, оба написания секретов — 0 расхождений. Коммит `bf68b79`. 2026-09-09
  - **Отличие от Go по структуре, не по поведению:** `Directives.secret` — список `NamedSecret`, а не карта. Порядок нужен для детерминированного вывода `status` и `check`; в Go порядок карты приходилось сортировать в каждом потребителе.
- [x] Шаг 12 — `resolver.zig`: `discover` (подъём по дереву, файлы профиля, `envee.d/*.toml`), `loadAll` (слияние, `stop_search_up`, полный список sources). 171 тест. **Исправлен баг Go: приоритет конфигов был вывернут наизнанку — см. раздел «Найдено в Go».** Коммит `64ec3f1`. 2026-09-09
- [x] Шаг 13 — `directive.zig` (порядок слоёв, coerce, шаблоны с топологическим порядком и поиском циклов, секреты, `prependToPath`), `directive/file.zig` (dotenv/json/toml), `path.zig` (совместимые с Go `clean`/`join`/`dirname`/`basename`/`absPath`, вынесены из template.zig). 203 теста. **Исправлен второй баг Go: `required` проверялся до применения переменных профиля — см. «Найдено в Go».** Дифференциал `apply` на 21 конфиге: 1 ожидаемое расхождение (исправленный баг), 20 совпадений. 2026-09-09
  - **Отступление:** YAML в `_.file` не поддерживается (в Go тянул `gopkg.in/yaml.v3`). Ни примеры, ни тесты им не пользуются; вместо молчаливого пропуска — внятная ошибка.
  - **Найдено по ходу:** `std.fs.path.join` не нормализует путь, поэтому `_.path = ["./bin"]` давал `<root>/./bin` вместо `<root>/bin` — мусор прямо в `$PATH`. Отсюда `path.zig` с семантикой Go `filepath.Join`.
- [x] Шаг 14 — `cli/args.zig`: дерево команд, persistent-флаги, `--flag=value` и `--flag value`, кластеры коротких флагов, счётчики, `--` passthrough, проверка числа аргументов, подсказки по расстоянию Левенштейна, рендер справки и ошибок в форме cobra. 224 теста. **Найден третий баг Go: `-v` не работает — см. «Найдено в Go».** 2026-09-09
- [x] Шаг 15 — `cli/root.zig` (дерево всех команд, `TrustGate`, `init`, `version`, `eval`, `evalDeps`, настройка лога), `main.zig` (контекст процесса, коды возврата), опции версии в `build.zig`. Временный `envee-dev` удалён, parity переведён на настоящий бинарь: 9/9. 237 тестов. **Найден четвёртый баг Go: `eval` дублирует $PATH — см. «Найдено в Go».** 2026-09-09
  - Работают `envee version`, `envee --version`, `envee --help`, справка по каждой команде, `envee init <shell>` (побайтно совпадает с Go), `envee eval <shell>`.
  - **Веха ещё не достигнута:** хранилище доверия появится на шаге 17, до тех пор `eval` всегда отказывает с E001 и кодом 3 — как и Go с пустым хранилищем. Проверка вынесена в `TrustGate`, тесты подставляют разрешающий вариант, поэтому `eval` покрыт целиком уже сейчас.
  - **Найдено по ходу:** в самом parity-скрипте счётчик внутри подоболочки терялся, и итог печатал «0 failed» при видимых FAIL. Исправлено.
- [ ] Шаг 16 — `resolve`, `diff`, `check`
- [ ] Шаг 17 — `trust/store.zig`, `summary.zig`, `prompt.zig`, trust gate, команды `trust`/`deny`
- [ ] Шаг 18 — `trust/sign.zig`, `trust/ssh_key.zig`, `trust --sign/--from`
- [ ] Шаг 19 — `plugin.zig`, команды `secret *`
- [ ] Шаг 20 — `envee-plugin-env` на Zig
- [ ] Шаг 21 — `status`, `exec`, `doctor`, `plugin list/info`, `daemon status`, `completion`, скрытые not-implemented
- [ ] Шаг 22 — cross-compile в `build.zig`, GitHub Actions
- [ ] Шаг 23 — ADR-0019/0020, README, удаление Go, homebrew formula

## Окружение (проверено 2026-09-09)

- macOS arm64, `zig 0.16.0` (`/opt/homebrew/Cellar/zig/0.16.0_1`), `zls 0.16.0`, Go 1.27 (для эталона и parity).
- Std lib: `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std` (путь даёт `zig env` → `lib_dir`).
- Shell'ы на машине: bash, zsh, fish. `nu` и `pwsh` отсутствуют — их живые тесты помечать `error.SkipZigTest`, если бинарь не найден.
- **Как проверять API std**: не по памяти и не по интернету. Только
  `grep -n "pub fn имя" <lib_dir>/std/...` или `zig std`. Zig 0.15 переписал
  Reader/Writer, 0.16 добавил обязательный `io: std.Io` почти во все
  I/O-вызовы; любой пример старше 2025 года в деталях неверен.

### Шпаргалка проверенных API 0.16.0

Сигнатуры взяты из установленной std. `io` везде — `std.Io`, получаемый в
`main` из `init.io` и передаваемый вниз по вызовам явно.

```zig
// main и контекст процесса
pub fn main(init: std.process.Init) !void
init.arena.allocator()          // арена на весь процесс, чистится сама
init.gpa                        // GPA (Debug: leak-check)
init.io                         // std.Io
init.minimal.args.toSlice(alloc) // ![]const []const u8 (так делает шаблон zig init 0.16.0)
init.environ_map                // *std.process.Environ.Map
env_map.get(key)                // ?[]const u8
env_map.iterator()              // .next() -> ?entry, поля key_ptr.*, value_ptr.*

// stdout/stderr/stdin
var buf: [4096]u8 = undefined;
var w: std.Io.File.Writer = .init(.stdout(), io, &buf); // .stderr() аналогично
const out = &w.interface;  // *std.Io.Writer: print/writeAll/writeByte/flush
var r: std.Io.File.Reader = .init(.stdin(), io, &buf); // &r.interface: *std.Io.Reader
std.debug.print("...", .{})   // stderr, без буфера, io не нужен

// Аллокация
std.ArrayList(T): unmanaged. `.empty`, append(gpa,x), insert(gpa,i,x),
  orderedRemove(i), clone(gpa), toOwnedSlice(gpa), deinit(gpa), .items
std.StringHashMap(V) — managed (`.init(gpa)`), std.StringHashMapUnmanaged(V) — `.empty` + gpa в методах.
  Аналогично StringArrayHashMap / StringArrayHashMapUnmanaged. В проекте использовать Unmanaged-варианты
  для единообразия с ArrayList.
std.fmt.allocPrint(gpa, fmt, args) ![]u8
std.heap.ArenaAllocator.init(child) / .allocator() / .deinit()

// Строки/срезы
std.mem.eql(u8, a, b), std.mem.order(u8, a, b) -> .lt/.eq/.gt
std.mem.indexOf / indexOfScalar / startsWith / endsWith / trim / tokenizeScalar / splitScalar
std.sort.lowerBound(T, items, ctx, cmpFn) usize; std.sort.binarySearch -> ?usize
std.mem.sort(T, items, ctx, lessThan)

// Файловая система (std.fs.* переехал в std.Io.*)
std.Io.Dir.cwd() Dir
dir.openFile(io, path, .{}) !File ; file.close(io)
dir.readFileAlloc(io, path, gpa, .unlimited) ![]u8  // Io.Limit
dir.createFile(io, path, .{ .permissions = .fromMode(0o600) }) !File  // CreateFileOptions.permissions: File.Permissions
dir.writeFile(io, .{ .sub_path=..., .data=... })
dir.statFile(io, path, .{}) !Stat   // .mtime, .kind
dir.iterate() -> it.next(io) !?Entry (.name, .kind)
dir.makePath(io, path), dir.deleteFile(io, path), dir.rename(...)
std.fs.path.join(gpa, &.{a,b}), .dirname(p) ?[]const u8, .basename(p), .isAbsolute(p), .resolve(gpa, &.{...})
std.process.currentPathAlloc(io, gpa) ![:0]u8
std.process.executablePathAlloc(io, gpa) ![:0]u8

// Процессы
std.process.spawn(io, .{ .argv = &.{...}, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit, .cwd = .inherit, .environ_map = null }) !Child
child.stdin.?  (File) -> writer(io,&buf), затем close(io)
child.stdout.? (File) -> reader(io,&buf) / readToEndAlloc (grep в Io/File.zig)
child.wait(io) !Term  (.exited => |code|)
child.kill(io)
std.process.run(gpa, io, .{ .argv = ..., .timeout = <Io.Timeout> }) !RunResult (.stdout, .stderr, .term)
  — stdin всегда .ignore, зато есть встроенный таймаут. Годится для `metadata` и для shell round-trip тестов.
  Io.Timeout = union(enum){ none, duration: Clock.Duration, deadline: Clock.Timestamp };
  Clock.Duration = .{ .raw = Io.Duration.fromSeconds(10), .clock = .awake }  (сверить конструкторы grep "Clock.Duration" Io.zig)
  Для `resolve` (нужен stdin): spawn(.stdin=.pipe,.stdout=.pipe) → записать → stdin.close(io) → читать stdout;
  таймаут — Io.Group/async (grep "pub const Group" Io.zig) либо watchdog-поток с child.kill(io).
std.process.exit(code: u8) noreturn

// Время
std.Io.Timestamp.now(io, .real) -> .nanoseconds: i96, .toSeconds() i64   // Clock: .real .awake .boot .cpu_process .cpu_thread
Форматирование RFC3339 писать руками (std.time без таймзон; нужен только UTC).

// JSON
std.json.parseFromSlice(T, gpa, bytes, .{ .ignore_unknown_fields = true }) !Parsed(T) (.value, .deinit())
std.json.parseFromSliceLeaky(T, arena, bytes, .{})
std.json.Stringify.valueAlloc(gpa, v, .{}) ![]u8
std.json.Stringify.value(v, .{}, writer)
std.json.Value — динамический вариант (object: ObjectMap, array, string, integer, bool, null)

// Крипто/кодирование
std.crypto.hash.sha2.Sha256.hash(data, &out32, .{})
std.crypto.sign.Ed25519: KeyPair.fromSecretKey(SecretKey.fromBytes(64 bytes)), kp.sign(msg, null) !Signature,
  Signature.fromBytes(64), sig.verify(msg, PublicKey.fromBytes(32)) !void
std.base64.standard.Encoder.encode(dest, src) / .Decoder.calcSizeForSlice(src) / .decode(dest, src)
std.fmt.bytesToHex(bytes_array, .lower) [N*2]u8   // принимает массив/указатель на массив известной длины
std.fmt.hexToBytes(out, hex) ![]u8
std.unicode.utf8Encode(cp: u21, out: []u8) !u3

// Тесты
std.testing.allocator, expect(bool), expectEqual(a,b), expectEqualStrings(a,b), expectEqualSlices(T,a,b), expectError(err, expr)
std.testing.tmpDir(.{}) TmpDir  (.dir: Io.Dir, .cleanup()) — для тестов resolver/trust/plugin
error.SkipZigTest — пропустить тест (нет бинаря shell'а и т.п.)
```

## Правила исполнения

1. **Определение «шаг закрыт»**: реализованы все функции из списка шага,
   перенесены все кейсы Go-тестов шага, `zig fmt --check src build.zig`
   чист, `zig build test --summary all` зелёный, parity (если применимо)
   зелёный, коммит сделан, чекбокс выше отмечен.
2. **Память**: в проде — арена процесса (`init.arena`), ничего не
   освобождаем. Публичные функции, которые аллоцируют, принимают
   `gpa: Allocator` первым/вторым параметром и возвращают `!T`. Функции
   без аллокатора не аллоцируют. Модули не копируют входные строки без
   необходимости (владение документируется в `//!` заголовке файла).
3. **Тесты** используют `std.testing.allocator` для структур с `deinit` и
   `ArenaAllocator` поверх него там, где много мелких строк. Утечка = провал.
4. **Ошибки**: error set с осмысленными именами + отдельная диагностика
   (шаг 8). Никаких `unreachable`/`catch unreachable` на пользовательском
   вводе. `@panic` только на нарушенных инвариантах.
5. **Один модуль**: все файлы `src/**` — части одного Zig-модуля,
   импорт через `@import("relative/path.zig")`. Каждый новый файл
   добавляется в `test { _ = @import(...); }` в `src/main.zig`, иначе его
   тесты не запускаются.
6. **Поведение = Go**, структура — идиоматичный Zig. Байтовая
   совместимость обязательна для: вывода `init <shell>`, `eval <shell>`,
   `resolve --json`, формата trust-entry JSON (кроме `version` и хеша, см.
   шаг 10), протокола плагинов.
7. **Windows**: best effort, не проверяется. Пути через `std.fs.path`,
   разделитель `PATH` — `:` как в Go-версии (`shell.PathListSeparator`).
8. **Коммиты**: `zig(<module>): <что сделано>`, без attribution-строк.

---

## Шаг 1 — `src/env.zig` (завершить)

**Цель.** Упорядоченная map env-переменных с diff/merge.

**Эталон.** `internal/env/env.go`, `internal/env/env_test.go`.

**Состояние.** Черновик `src/env.zig` уже содержит `Entry`, `Map{entries: ArrayList(Entry)}` отсортированный по ключу, `Slot`/`find` через `std.sort.lowerBound`, `setEntry`, `unset`, `DiffOp`, `diff` (merge-walk двух сортированных списков). Прочитать его первым.

**Сделать.**
- Внутри `Map`: `len`, `get(key) ?[]const u8`, `getEntry(key) ?Entry`, `set(m,gpa,key,value)`, `keys(m,gpa) ![]const []const u8` (уже отсортированы, без сортировки), `clone(m,gpa) !Map`, `merge(m,gpa,other)` (other побеждает), `asExport(m,gpa) ![]const []const u8` (`KEY=VALUE` через `allocPrint`), `fromEnviron(gpa, *const std.process.Environ.Map) !Map`.
- Тесты (порт всех кейсов `env_test.go` + два новых): set/get/unset; перезапись на месте с сохранением порядка; keys sorted; diff set/change/unset и **отсортированность результата** (W,Y,Z); diff одинаковых map пуст; merge override; clone независим; asExport.
- В `src/main.zig` добавить `test { _ = @import("env.zig"); }`.

**Готово когда.** `zig build test --summary all` → 9 tests passed (1 smoke + 8).

**Коммит.** `zig(env): port Map, diff and merge`

---

## Шаг 2 — `src/shell/escape.zig`

**Цель.** Все функции экранирования, без адаптеров.

**Эталон.** `internal/shell/escape.go` (BashEscape, ansiCEscape, DoubleQuoteEscape), `FishEscape`/`NuEscape`/`PwshEscape` в `internal/shell/shell.go` (строки ~402–520, ~672+), тесты `shell_test.go` (часть про escape), `escape_roundtrip_test.go`.

**Сделать.**
- `pub fn bashEscape(gpa, s) ![]const u8` — три режима: `""`→`''`; только `[A-Za-z0-9./-_:=,+@%]`→как есть; есть байт `<0x20`, `0x7f` или `>=0x80`→ANSI-C `$'…'` (`\n \t \r \\ \'` и `\xHH` для остальных — сверить с `ansiCEscape` в Go); иначе `'…'` с заменой `'`→`'\''`.
- `pub fn doubleQuoteEscape(gpa, s)`, `pub fn fishEscape(gpa, s)` (сначала `\`→`\\`, потом `'`→`\'`, обернуть в `'`), `pub fn nuEscape`, `pub fn pwshEscape` — по Go.
- Предпочтительно писать в `*std.Io.Writer` (`pub fn writeBashEscaped(w, s) !void`) и иметь alloc-обёртки; это пригодится в шаге 3.
- Тесты: все табличные кейсы из Go. Round-trip тест: для набора значений (пробелы, кавычки, `$`, backtick, `\n`, `\`, юникод, пустая строка, строка с `'` в конце, `\` в конце) запустить `bash -c "printf %s <escaped>"` / `zsh -c` / `fish -c` через `std.process.run` и сравнить stdout с исходником. Если shell не найден (`error.FileNotFound`) — `return error.SkipZigTest`.

**Готово когда.** Тесты зелёные, включая round-trip на bash/zsh/fish.

**Коммит.** `zig(shell): port escaping with live shell round-trip tests`

---

## Шаг 3 — `src/shell/shell.zig` + адаптеры

**Цель.** `Adapter` для bash/zsh/fish/nu/pwsh: `init`, `export`, `unset`, `setPath`, `escape`, плюс `renderDiff` (nu) и `renderFastPath` (bash/zsh/fish).

**Эталон.** `internal/shell/shell.go` целиком, `hooks_test.go`, `fastpath_test.go`, `hook_exec_test.go`, `cli/deps.go` (что попадает в deps).

**Сделать.**
- `pub const Name = enum { bash, zsh, sh, fish, nu, pwsh }`; `pub fn detect(name: []const u8) ?Name` (case-insensitive; `sh`→bash, `nushell`→nu, `powershell`→pwsh).
- `pub const Adapter = union(enum) { bash, zsh, fish, nu, pwsh }` с методами, диспетчер через `switch`. Методы пишут в `*std.Io.Writer`:
  - `writeInit(a, w, self_path)` — hook-шаблоны **байт в байт** из Go (`{{.SelfPath}}` подставить). Хранить шаблоны как многострочные литералы `\\` в отдельных файлах `bash.zig`, `zsh.zig`, `fish.zig`, `nu.zig`, `pwsh.zig`.
  - `writeExport(a, w, key, escaped_value)`, `writeUnset(a, w, key)`, `writeSetPath(a, w, dirs)`, `writeEscaped(a, w, s)`.
  - `supportsDiffRender(a) bool` (только nu) и `writeDiff(a, w, set: []const KV, unset: []const []const u8)` — JSON `{"set":{...},"unset":[...]}` + `\n`; `unset` отсортирован; `set` — сериализовать в порядке отсортированных ключей (Go `json.Marshal` map сортирует ключи).
  - `supportsFastPath(a) bool` (bash/zsh/fish) и `writeFastPath(a, w, deps)`: bash/zsh `__envee_deps=(<bashEscape каждого> ...);\n`; fish `set -g __envee_deps <fishEscape...>\n` (пустой список → `set -g __envee_deps\n`).
- Тесты: `hooks_test.go` (содержимое init для каждого shell: наличие ключевых строк), `fastpath_test.go` (рендер deps; живые тесты hook-а на bash/zsh/fish через `std.process.run` с `-c` — перенести, SkipZigTest если shell отсутствует), `hook_exec_test.go`.

**Готово когда.** Тесты зелёные.

**Коммит.** `zig(shell): port adapters, hook templates, nu diff and fast path`

---

## Шаг 4 — `scripts/parity.sh`

**Цель.** Автоматическая сверка Go и Zig бинарей.

**Сделать.** Скрипт из раздела 5 `zig-rewrite.md`. Собирает `make build` и `zig build`. Временно, пока нет CLI (шаг 15), сверка `init <shell>` делается через маленький тестовый exe: добавить в `build.zig` второй exe `envee-dev` из `src/dev_main.zig`, который принимает `init <shell>` и печатает `writeInit` с подставленным путём Go-бинаря. Удалить `dev_main.zig` в шаге 15.
- `init`: сравнивать после `sed "s#$GO_BIN#SELF#; s#$ZIG_BIN#SELF#"`.
- Заготовки (закомментированы до шага 15): `eval bash|zsh|fish|nu|pwsh` и `resolve --json` в каждом `examples/*/` под `env -i HOME PATH ENVEE_PROFILE`, `check` для examples.

**Готово когда.** `./scripts/parity.sh` печатает `ok init bash|zsh|fish|nu|pwsh`.

**Коммит.** `zig: parity script against the Go binary`

---

## Шаг 5 — `src/dotenv.zig`

**Эталон.** `internal/dotenv/parse.go`, `parse_test.go` (282 строки — полная спецификация).

**Сделать.** `pub fn parse(gpa, data) !std.StringArrayHashMap([]const u8)` (порядок вставки нужен для детерминизма) и `parseWithExpansion(gpa, data, env_lookup)` где lookup — `*const fn(ctx, key) ?[]const u8` или `anytype`. State machine 1:1 с Go: `export ` префикс, `KEY=VALUE`, одинарные кавычки (буквально), двойные (escape `\n \t \" \\`, `$VAR`/`${VAR}` при expansion), многострочные в кавычках, комментарии `#` вне кавычек, `KEY:` синтаксис если Go его принимает. Ошибки: `error.UnterminatedQuote`, `error.InvalidKey` и т.д. с номером строки в диагностике (шаг 8; до него — просто error set).
- `parseFile(gpa, io, path)`.

**Готово когда.** Все кейсы `parse_test.go` зелёные.

**Коммит.** `zig(dotenv): port the state-machine parser`

---

## Шаг 6 — `src/template.zig`

**Эталон.** `internal/template/template.go`, `template_test.go`; фильтры: `upper lower trim default("x") abspath realpath dirname basename quote json base64`.

**Сделать.** `Context{config_root, profile, cwd, env: *const env.Map, os_env: *const env.Map}`; `pub fn render(gpa, io, tpl, ctx) ![]const u8`. Выражения: `config_root`, `profile`, `cwd`, `env.X`. `realpath` и `abspath` требуют `io`. Ошибки: `error.UnclosedTemplate`, `error.UnknownFilter`, `error.UnknownVariable` — сверить с Go, что именно ошибка, а что пустая строка.
- Детект циклов живёт в `directive` (шаг 13), здесь только рендер.

**Готово когда.** `template_test.go` зелёный.

**Коммит.** `zig(template): port the Jinja-lite renderer`

---

## Шаг 7 — `src/paths.zig`

**Эталон.** `internal/paths/paths.go`, `paths_test.go`, ADR-0012. Поведение `adrg/xdg` на macOS (проверено в `adrg/xdg@v0.5.3/paths_darwin.go`): без переменных `ConfigHome = DataHome = RuntimeDir = ~/Library/Application Support`, `CacheHome = ~/Library/Caches`. Linux: `~/.config`, `~/.local/share`, `~/.cache`, `$XDG_RUNTIME_DIR` (fallback — проверить в `paths_unix.go` той же библиотеки: `go env GOMODCACHE`).

**Сделать.** `Paths` struct, инициализируемый из `*const Environ.Map` + home: `config()`, `data()`, `cache()`, `runtime()`, `trustStore()`, `pluginMetadataCache()`, `socket()`, `lockFile()`, `ensureDirs(io)` (0755, runtime 0700). Все возвращают пути, выделенные в переданной арене.

**Готово когда.** Тесты: с `XDG_*` установленными и без (macOS-дефолты).

**Коммит.** `zig(paths): XDG paths with adrg/xdg-compatible macOS defaults`

---

## Шаг 8 — `src/errs.zig`, `src/log.zig`

**Эталон.** `internal/errs/errs.go`, `docs/errors.md` (коды E001–E015), `internal/log/log.go`, `redact_test.go`, `cli/root.go` (`ExitCode`).

**Сделать.**
- `errs.zig`: `pub const Code = enum { e001, ... e015 }` с `docUrl()`, `exitCode()` (E001,E010→3; E002,E003,E007,E008,E012→4; E004,E009,E011,E015→5; иначе 1); `pub const Diag = struct { code, severity, summary, hint, context: list KV, cause: ?anyerror }` и `format(w)` в том же тексте, что Go `Error()` (см. `errs.go:92`). Механизм передачи: `pub const Error = error{ TrustRequired, TrustDenied, ConfigParse, ConfigValidation, PluginError, TemplateError, Cycle, RequiredVar, PluginNotFound, Daemon, FileNotFound, PermissionDenied, VersionIncompatible, Network }` + thread-local `var last: ?Diag` с `pub fn fail(d: Diag) Error` который сохраняет диагностику и возвращает ошибку. CLI на верхнем уровне печатает `last`. Конструкторы: `trust(path,hash)`, `configParse(path,line,col,detail)`, `configValidation`, `requiredVar`, `pluginNotFound`, `cycleDetected(chain)`.
- `log.zig`: уровни trace/debug/info/warn/error, формат text/json, `quiet`, глобальный `configure(opts)`, функции `debug/info/warn/err(fmt, args)` в stderr; редакция: значения для ключей, похожих на секреты (`nameLooksSensitive` из `trust/summary.go`) и помеченных `redacted` → `***REDACTED***`. Порт `redact_test.go`.

**Готово когда.** Тесты зелёные.

**Коммит.** `zig(errs,log): error codes, diagnostics and redacting logger`

---

## Шаг 9 — `src/toml/lexer.zig`

**Цель.** Токенизатор подмножества TOML 1.0.

**Сделать.** `Token{ kind, text, line, col }`; kinds: `bare_key, string_basic, string_literal, string_ml_basic, string_ml_literal, integer, float, bool, lbracket, rbracket, dlbracket, drbracket, lbrace, rbrace, equals, dot, comma, newline, eof`. Escape-последовательности в basic strings: `\b \t \n \f \r \" \\ \uXXXX \UXXXXXXXX` (через `std.unicode.utf8Encode`), line-ending backslash в multiline. Комментарии `#` до конца строки. Числа: `+`/`-`, `_` разделители, hex/oct/bin — можно отложить. Даты — **не поддерживаем**, лексер даёт `error.UnsupportedDateTime` с позицией.
- Тесты: каждый вид токена, позиции, ошибки (незакрытая строка, неверный escape).

**Коммит.** `zig(toml): lexer`

---

## Шаг 10 — `src/toml/value.zig`, `src/toml/parser.zig`, канонический хеш

**Сделать.**
- `Value = union(enum) { string: []const u8, integer: i64, float: f64, boolean: bool, array: []Value, table: *Table }`, `Table = std.StringArrayHashMap(Value)` (порядок вставки сохраняется). Хелперы `get(path "a.b.c")`, `asString/asBool/asInt/asArray/asTable` возвращающие `?T`.
- Парсер: `[table]`, `[a.b.c]`, dotted keys `a.b = 1`, inline tables `{ k = v, ... }`, массивы (многострочные, trailing comma), `[[array.of.tables]]` — сделать, это дёшево поверх остального. Ошибка на дублирующемся ключе/переопределении таблицы, как требует TOML. Все ошибки → `error.Parse` + диагностика с `line:col` (через `errs`).
- **Канонический хеш v2**: `pub fn canonicalWrite(w, table)` — детерминированная сериализация: ключи отсортированы, строки в basic-кавычках с минимальным escape, целые как есть, bool `true/false`, массивы `[a, b]`, вложенные таблицы как dotted `[a.b]` секции в отсортированном порядке. `canonicalHash(gpa, table) "sha256:<hex>"`. Это **не совпадает** с Go (BurntSushi re-marshal) — trust-записи переезжают на `version: 2` (шаг 17). Зафиксировать формат в тесте с golden-строкой.
- Тесты: все `examples/*/envee.toml` парсятся; таблица кейсов синтаксиса; golden canonical-вывод; идемпотентность (parse(canonical(x)) == x).
- Fallback: если после честной попытки парсер не проходит examples — `zig fetch --save git+https://github.com/sam701/zig-toml` и адаптер поверх; задокументировать в ADR-0019.

**Коммит.** `zig(toml): parser, value tree and canonical hash v2`

---

## Шаг 11 — `src/config.zig`

**Эталон.** `internal/config/config.go`, `parse.go` (`directivesFromMap`, `flattenProfileEnv`, лифт `watch`), `parse_test.go`, `directives_test.go`, ADR-0002, ADR-0010.

**Сделать.** Типы `Config, Profile, Directives, FileRef, PathEntry, ScriptRef, SecretRef, SourceRef, SourceFile` как в Go, но `Env` — `StringArrayHashMap(toml.Value)` (значение остаётся динамическим, как `any` в Go). `parseBytes(gpa, path, data) !*Config` делает: decode → default schema → лифт `env._`→`Directives` (`file` может быть строкой, массивом строк, массивом таблиц или таблицей — см. `directivesFromMap`), лифт inline-ключей `[profiles.X]` в `Profile.env`, лифт `watch`, `file_hash = canonicalHash`, `sources = [{path, hash}]`, `mod_time` через `statFile`. `parse(gpa, io, path)`. `secretRefs(gpa)` — merge двух spellings. `sortedKeys(gpa)`.

**Готово когда.** `parse_test.go`, `directives_test.go` зелёные.

**Коммит.** `zig(config): schema types and post-processing`

---

## Шаг 12 — `src/resolver.zig`

**Эталон.** `internal/resolver/resolver.go`, `resolver_test.go`, ADR-0003.

**Сделать.** `Resolver{cwd, config_dir, profile, stop_at_root}`; `discover(gpa, io) ![]const []const u8` — порядок: в каждой директории от cwd вверх: `envee.local.<profile>.toml`, `envee.<profile>.toml`, `envee.local.toml`, `envee.toml`, `envee.d/*.toml` (отсортированы, без `.`-префикса); стоп на `/` или `stop_at_root`; затем `<config_dir>/config.toml`. `loadAll` — parse каждого, `mergeInto` (скаляры: later wins; env/profiles — merge; directives — append; sources — append), стоп после первого `stop_search_up`. Нет файлов → `error.FileNotFound` с диагностикой «no envee.toml found (searched from X upward)».

**Тесты.** Порт `resolver_test.go` с временными директориями (`std.testing.tmpDir` — проверить API в 0.16, grep `tmpDir` в testing.zig).

**Коммит.** `zig(resolver): discovery and merge`

---

## Шаг 13 — `src/directive.zig`, `src/directive/file.zig`

**Эталон.** `internal/directive/directive.go` (`Apply`, `coerceValue`, `formatAnyArray`, `validateRequired`, `evaluateTemplates` с детектом циклов, `expandPathTemplates`, `PrependToPath`), `file.go`, `directive_test.go`.

**Сделать.**
- `Result{env: env.Map, path_prepend: []const []const u8, redacted_keys}`; `ApplyOptions{config_root, profile, cwd, os_env: *const env.Map}`; `PluginResolver = struct { ctx: *anyopaque, resolveFn: *const fn(ctx, gpa, source, ref) anyerror![]const u8 }` (nil-резолвер → значения `__UNRESOLVED__:source:ref`, как в Go MVP).
- Порядок в `apply`: 1) `_.file` в порядке TOML; 2) profile env (+ `required`); 3) `[env]` (пропуск `_` и meta-ключей `watch`, `schema`...; secret shorthand `{source, ref}` → лифт в `directives.secret`); 4) `_.path` (относительные без `{{` → join с config_root); 5) templates в топологическом порядке с детектом цикла (E007); 5b) templates в PATH; 6) secrets через резолвер, `required` → E008; 7) `false` → unset; redacted keys.
- `coerceValue`: string; int → decimal; bool → `true/false`; float → Go `%g` (сверить формат на тестах); inline table → `value` + `redact`; array → `formatAnyArray` (Go `%v` элементов через `[a b]`? — прочитать точно и повторить).
- `file.zig`: `applyFile(gpa, io, config_root, ref, set_fn)`: форматы dotenv (по умолчанию и по расширению), json (плоский объект; вложенное — `flatten` с `_`-префиксами как в Go), toml (наш парсер), **yaml → `error.UnsupportedFormat` с hint «yaml is not supported in the Zig build»** (проверить, есть ли yaml в тестах; если есть — тест переписать на ожидание ошибки и записать в «Найдено/изменено»). `required=false` + отсутствие файла → пропуск.
- `prependToPath(gpa, dirs, current) []const u8` — дедупликация как в Go.

**Готово когда.** `directive_test.go` зелёный.

**Коммит.** `zig(directive): apply orchestrator and file loaders`

---

## Шаг 14 — `src/cli/args.zig`

**Цель.** Замена cobra: подкоманды, persistent-флаги, `--help`, `--version`, ошибки usage.

**Сделать.** Декларативное описание: `Command{ name, short, long, flags: []Flag, args: ArgSpec (exact N / min N / passthrough после `--`), subcommands, run: *const fn(*Ctx, ParsedArgs) anyerror!void, hidden: bool }`. Persistent-флаги корня: `--config --profile --log-level --log-format --color -q/--quiet -v/--verbose (счётчик, -vv) --debug --no-telemetry`. Поддержать `--flag=value` и `--flag value`, `-q`, кластер коротких не нужен. `--help`/`-h` на любом уровне печатает usage в стиле cobra (Usage/Available Commands/Flags; скрытые не показывать). Неизвестная команда → «unknown command "x" for "envee"» + подсказки по префиксу/расстоянию Левенштейна (Go `SuggestionsFor`), exit 2.
- Тесты: разбор флагов, ошибки, help-рендер, `--` passthrough.

**Коммит.** `zig(cli): argument parser and command tree`

---

## Шаг 15 — `src/cli/root.zig`, `init`, `version`, `eval` — ВЕХА

**Эталон.** `cli/root.go`, `cli/init.go`, `cli/eval.go`, `cli/deps.go`, `cli/trustgate.go` (пока — заглушка: trust всегда «требуется», см. ниже), `cli/registry.go`/`plugins_lazy.go` (`dispatcherFor`: без секретов в конфиге плагины не ищем), `eval_golden_test.go`, `cmd/envee/main.go`.

**Сделать.**
- `main.zig`: собрать `Ctx{arena, io, env_map, paths, stdout, stderr}`; `args.run` → при ошибке напечатать `errs.last` (или текст ошибки) в stderr, `std.process.exit(exitCode)`.
- `version` — из `build.zig` через `b.addOptions()` (`-Dversion=`, `-Dcommit=`, `-Ddate=`; дефолт `0.0.0-dev`), формат как Go: `<v> (commit <c>, built <d>, zig <ver>)`.
- `init <shell>` — `writeInit` с `executablePathAlloc`.
- `eval <shell>` — pipeline из `eval.go`: cwd → resolver(profile: flag > `ENVEE_PROFILE`) → loadAll → **trust gate** → profile (flag/env/config) → config_root = dirname(cfg.path) → directive.apply → адаптер → `renderShellDiff` (PATH отдельно через `setPath`, остальное отсортировано; nu через `writeDiff`) → fast-path deps (`evalDeps`: cwd, каждый source path и его dirname, watched paths, файлы `_.file` — прочитать `deps.go` полностью; только абсолютные, без дублей, порядок сохранить) → stdout.
- Trust gate на этом шаге: реализовать интерфейс `ensureTrusted(cfg)` с временной реализацией «читать store как в шаге 17 невозможно → всегда E001». Чтобы веха была полезной, **сделать шаг 17 сразу следом**, а parity для `eval` включать после него. До этого сравнивать `eval` с `ENVEE`-store пустым: обе версии должны давать одинаковую E001-ошибку и exit 3.
- Golden-тесты `eval_golden_test.go` перенести как есть (они кладут trust-записи в tmp `XDG_DATA_HOME` — понадобится шаг 17; пометить их `SkipZigTest` до него, снять после).

**Готово когда.** `zig build` даёт `zig-out/bin/envee`; `envee init zsh`, `envee version`, `envee eval zsh` (после шага 17) работают; parity `init` зелёный.

**Коммит.** `zig(cli): root command, init, version and eval`

---

## Шаг 16 — `resolve`, `diff`, `check`

**Эталон.** `cli/resolve.go` (text и `--json`; формат JSON сверить побайтно — ключи отсортированы, отступы), `cli/diff.go`, `cli/check.go`, `cli/check_impl.go` (все finding-коды и правила, `--strict`, `--json`), `check_test.go`.

**Готово когда.** `check_test.go` зелёный; parity `resolve --json` и `check` на всех examples (кроме тех, где trust нужен — после 17).

**Коммит.** `zig(cli): resolve, diff and check`

---

## Шаг 17 — `src/trust/store.zig`, `summary.zig`, `prompt.zig`, gate, `trust`/`deny`

**Эталон.** `internal/trust/store.go`, `check.go`, `summary.go`, `prompt.go`, `cli/trust.go`, `cli/trustgate.go`, `store_test.go`, `summary_test.go`, ADR-0004.

**Сделать.**
- `Entry` JSON: `signature?`, `expires_at` (RFC3339, опускать если zero), `trusted_at`, `file_hash`, `file_path`, `trusted_by`, `tool_version`, `comment?`, `version` — **писать `2`**; читать 1 и 2, но запись v1 считать `Unknown` (хеш другой по определению) — это и есть миграция: пользователь один раз делает `envee trust`. Время: `Io.Timestamp.now(io, .real)` → RFC3339 форматирование написать руками (UTC, `YYYY-MM-DDTHH:MM:SSZ`; для парсинга — тоже руками, только этот формат).
- Store: `entryPath(hash)` = `<trustStore>/<sanitize(hash)>.json`; deny keyed by `pathHash(path)` в отдельном имени файла (прочитать `denyPath`); `status`, `trust(ttl)`, `put`, `get`, `deny`, `undeny`, `revoke`, `list`; запись атомарно (tmp + rename), права 0600, директория 0700.
- `summary.zig`: `BuildSummary(cfg)` и `String()` — текст prompt-а как в Go (кол-во env, redact, path adds, files, secrets с источниками, sensitive-имена). `showDiff`.
- `prompt.zig`: `[Y/n/d(iff)/s(kip)/q(uit)]`, чтение stdin построчно, `--yes`/non-tty поведение как в Go.
- `trustgate`: для каждого `cfg.sources` → `store.status(path, hash)`; Denied→E010, иначе не Trusted→E001 с hint `envee trust`.
- Команды `trust [path] [--ttl] [--yes] [--comment]`, `deny [path]`, `status --trust` (часть; полный `status` — шаг 21).

**Готово когда.** `store_test.go`, `summary_test.go` зелёные; golden `eval` тесты из шага 15 включены и зелёные; parity `eval` для всех shell на всех examples после `envee trust --yes` в обоих бинарях (каждый со своим `XDG_DATA_HOME`).

**Коммит.** `zig(trust): store, summary, prompt and the eval trust gate`

---

## Шаг 18 — `src/trust/sign.zig`, `src/trust/ssh_key.zig`

**Эталон.** `internal/trust/sign.go`, `sign_test.go`, `cli/trust.go` (`--sign --key --export`, `--from --public-key`), `trust_share_test.go`.

**Сделать.**
- `ssh_key.zig`: `loadPrivateKey(gpa, io, path) ![64]u8` — OpenSSH формат: PEM-обёртка `-----BEGIN OPENSSH PRIVATE KEY-----`, base64 → `openssh-key-v1\0`, поля (u32-length-prefixed): ciphername (`none`, иначе `error.PassphraseProtected` с hint из Go), kdfname, kdfoptions, u32 nkeys=1, pubkey blob, private blob: checkint×2, keytype `ssh-ed25519` (иначе `error.NotEd25519`), pub(32), priv(64), comment, padding. `loadPublicKey(gpa, io, path) ![32]u8` — строка `ssh-ed25519 <b64> [comment]`, blob = str(`ssh-ed25519`) + str(pub32). `keyId(pub)` — как в Go `KeyID` (прочитать: вероятно `SHA256:<base64-без-padding>`).
- `sign.zig`: `signingPayload(entry)` — **точно** как Go (какие поля, порядок, JSON без signature), `signEntry(entry, priv, now)`, `verifyEntry(entry, pub)`; `error.NoSignature`, `error.BadSignature`, `error.AlgorithmMismatch`.
- Тесты: сгенерировать ключ в тесте через `ssh-keygen -t ed25519 -N "" -f tmp` (SkipZigTest если нет `ssh-keygen`) + фикстуры из Go-тестов; cross-check: подпись, сделанная Go-бинарём (`bin/envee trust --sign --export`), верифицируется Zig и наоборот — добавить в parity как отдельный шаг.

**Коммит.** `zig(trust): ed25519-signed entries with OpenSSH key parsing`

---

## Шаг 19 — `src/plugin.zig`, команды `secret *`

**Эталон.** `internal/plugin/exec.go`, `registry.go` (типы Request/Response/Metadata/PluginError — JSON-поля точно), `dispatcher.go`, `exec_test.go` (+ `testdata/fakeplugin`), `cli/secret.go`, `cli/plugin_impl.go`, `plugins_lazy.go`, ADR-0007.

**Сделать.**
- Discovery: `envee-plugin-*` в каждом каталоге `PATH` (исполняемые, не директории) и в `paths.pluginMetadataCache()`-соседнем каталоге плагинов (прочитать `discoverFromPath`/`Registry.Discover`); имя = суффикс.
- `ExecPlugin{name, path, metadata?}`: `fetchMetadata(gpa, io)` (`<bin> metadata`, таймаут 5s), `resolveSecret(gpa, io, source, ref)` (`<bin> resolve`, JSON-запрос в stdin: `api_version:1, request_id: "req-<nanos>", spec:{ref}, context:{config_root: $ENVEE_CONFIG_ROOT, cwd: $ENVEE_CWD, profile: $ENVEE_PROFILE, env: <весь os env>}`, таймаут 10s, stderr наследуется; ответ `{status: ok|error, value:{type,value}, error:{code,message}}`; при non-zero exit попытаться распарсить error-ответ из stdout).
- Таймаут: `spawn` + отдельный `std.Thread`, который ждёт `wait`, а основной — `Io` sleep/timer; либо поток-watchdog с `kill`. Проверить, есть ли в 0.16 `Io` deadline-механизм для `Child` (grep `timeout\|deadline` в process.zig); если есть — использовать его.
- `Dispatcher{map name→ExecPlugin}` реализует `directive.PluginResolver`; `dispatcherFor(cfg)`: если `cfg.secretRefs()` пуст — не искать плагины вовсе (perf-фикс `08e71f7`).
- `secret set KEY=VAL / unset / list / get` — через плагин `env` (прочитать `secret.go`: команда вызывает бинарь плагина или пишет файл напрямую?) — повторить.
- Тесты: порт `exec_test.go` с fake-плагином. Fake-плагин — маленький Zig exe `src/testing/fakeplugin.zig`, собираемый в `build.zig` как test-артефакт, путь передаётся тестам через `b.addOptions` или env.

**Коммит.** `zig(plugin): exec protocol, discovery, dispatcher and secret commands`

---

## Шаг 20 — `envee-plugin-env` на Zig

**Эталон.** `plugins/env/main.go`, `pkg/sdk-go/protocol.go` (формат), `pkg/sdk-go/protocol_test.go`.

**Сделать.** `src/plugins/env_main.zig` → exe `envee-plugin-env` в `build.zig`. Подкоманды `metadata`, `resolve`, `version`; хранилище `<paths.data()>/secrets/env.json` (0600), формат файла как у Go-плагина (совместимость: пользователи с существующим файлом). Ошибки `not_found`, `invalid_spec`.
- Тест совместимости: Go `pkg/sdk-go/testdata/demoplugin` (собрать `go build`) резолвится Zig-ядром; Zig-плагин резолвится Go-ядром. Добавить в parity.

**Коммит.** `zig(plugins): envee-plugin-env`

---

## Шаг 21 — остальные команды

**Эталон.** `cli/status.go`, `cli/exec.go`, `cli/diag.go` (`doctor`), `cli/auxiliary.go` (`plugin list/info`, `daemon status/start/stop`), `cli/check.go` (`completion`, `debug`), `cli/notimpl.go`, `cli/trust.go` (`status --trust`), `daemon/daemon.go` (только `status`: проверка сокета/lock).

**Сделать.** Все команды с тем же текстовым выводом. `exec -- cmd` — `spawn` с `environ_map` из resolved env, проброс exit-кода, stdio inherit. `completion <shell>` — генерировать из дерева команд для bash/zsh/fish (минимально: имена команд и флагов). Скрытые (`plugin install`, `daemon start/stop`, `upgrade`, `debug`, `telemetry`, `doctor --fix`) — сообщение «not implemented» и exit 1, как Go.

**Готово когда.** `envee --help` и help каждой команды совпадают с Go по составу команд (текст может отличаться в мелочах форматирования cobra — зафиксировать parity как «одинаковый список команд», не побайтно). parity `status`, `doctor` (после нормализации путей/версий).

**Коммит.** `zig(cli): status, exec, doctor, plugin, daemon, completion`

---

## Шаг 22 — cross-compile и CI

**Сделать.**
- `build.zig`: опции `-Dversion -Dcommit -Ddate`; `zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe`; `strip = true` в release; цели `aarch64-linux-musl`, `x86_64-macos`, `aarch64-macos`, `x86_64-windows` (best effort). Шаг `zig build release` собирающий все пять в `zig-out/release/<target>/`.
- `.github/workflows/ci.yml`: `mlugg/setup-zig@v2` с `version: 0.16.0`; матрица ubuntu/macos (windows — только сборка); установка fish/zsh как сейчас; `zig fmt --check`, `zig build test`, parity против Go (пока Go есть), cross-compile job.
- `Makefile`: цели `zig-build`, `zig-test`, `parity`.

**Коммит.** `ci: build and test the Zig implementation`

---

## Шаг 23 — документация и удаление Go

**Сделать.**
- `docs/adr/0019-language-zig.md` (Supersedes 0001: мотивация — обучение + hot path без GC; потери — cobra, goreleaser, x/crypto/ssh, yaml в `_.file`; выигрыши — бинарь ~1 MB, старт <1 ms, cross-compile без внешних инструментов). `docs/adr/0020-canonical-hash-v2.md` (формат, миграция trust-store, `version: 2`).
- README: install (архивы из релизов; `brew` через tap с prebuilt), Development (`zig build`, `zig build test`), таблица «Cross-platform» — binary size обновить, «Go 1.24+» badge → «Zig 0.16».
- CHANGELOG: `## 0.4.0 — Rewritten in Zig`, пункт про обязательный re-trust и про yaml.
- `homebrew-tap/Formula/envee.rb`: prebuilt-архивы с `sha256` per-arch (без `go` build).
- Удалить: `cmd/`, `internal/`, `plugins/env/main.go`, `go.mod`, `go.sum`, `.golangci*.yml`, `.goreleaser*.yaml`, `Makefile` Go-цели, `scripts/parity.sh`, `src/dev_main.zig` (если ещё есть). `pkg/sdk-go` → перенести в отдельный репозиторий `envee-sdk-go` с собственным `go.mod` (или оставить с своим `go.mod` в подкаталоге — решает владелец, спросить).
- `.github/workflows/release.yml`: теги → `zig build release` → архивы + `checksums.txt` + подпись (cosign/minisign как сейчас в goreleaser-конфиге).

**Коммит.** `chore: remove the Go implementation` (отдельно от документации).

---

## Открытые решения

| Вопрос | Когда решать | Дефолт, если владелец не ответил |
|---|---|---|
| Свой TOML vs `sam701/zig-toml` | конец шага 10 | свой; fallback на библиотеку |
| yaml в `_.file` | шаг 13 | не поддерживать, понятная ошибка |
| Судьба `pkg/sdk-go` | шаг 23 | оставить в подкаталоге со своим `go.mod` |
| Windows-поддержка | шаг 22 | собирать, не тестировать, пометить experimental |
| Формат `version` в trust-entry v2 | шаг 17 | `2`, v1 читается как Unknown |

## Найдено в Go (для переноса правильного поведения)

### ⚠️ `eval` дублирует текущий $PATH (`internal/cli/eval.go`)

**Симптом.** `renderShellDiff` передаёт в `adapter.SetPath` ПОЛНЫЙ новый
`$PATH` (`filepath.SplitList(newPath)`), а адаптер по своему контракту
дописывает к полученному списку ещё и `:"$PATH"`. Текущий `PATH` попадает в
результат дважды. Контракт адаптера при этом верен — его собственный тест
`TestSetPathRoundTrip` передаёт ТОЛЬКО новые каталоги; неверен вызывающий.

**Проверено на выпущенной версии**, `examples/basic` при `PATH=/usr/bin:/bin`:

```
export PATH=<3 каталога проекта>:/usr/bin:/bin:"$PATH";
```

После применения в PATH семь записей вместо пяти, `/usr/bin` и `/bin`
продублированы. Дальше не растёт (дедупликация при следующем вызове идёт
против уже испорченного PATH), но лишний хвост остаётся навсегда.

Затрагивает bash, zsh, fish и pwsh. Nushell не затронут: там `renderDiff`
кладёт полный путь обычным присваиванием.

**В Zig** в `writeSetPath` передаются только новые каталоги, отсутствующие в
текущем `$PATH`. Покрыто тестами `eval does not duplicate the existing PATH`
и `eval skips a path entry already present`.

### Флаг `-v` не работает (`internal/cli/root.go`)

Объявлен булевым (`pf.BoolP("verbose", "v", false, ...)`), а читается как
число (`verbose, _ := cmd.Flags().GetInt("verbose")`). `GetInt` на булевом
флаге возвращает ошибку, её отбрасывают, значение остаётся нулём, и ветка
`if verbose > 0` никогда не выполняется. `-v` и `-vv` не делают ничего.

Проверено пробой на cobra: `GetInt(verbose) = 0, err = trying to get int
value of flag of type bool`, при этом `GetBool(verbose) = true`.

В Zig это настоящий счётчик (`FlagKind.counter`), покрыт тестом
`verbose is a real counter`.

### ⚠️ `required` проверяется до применения переменных профиля (`internal/directive/directive.go`)

**Симптом.** В `Apply` вызов `validateRequired(prof, res.Env)` стоит на шаге 2,
ДО того как в `res.Env` попадают переменные самого профиля (шаг 2, ниже по
коду) и таблица `[env]` (шаг 3). В этот момент в `res.Env` лежат только
переменные из `_.file`. Поэтому `required = ["X"]` падает даже тогда, когда
X объявлен тут же, в `[profiles.<name>.env]`.

**Проверено на выпущенной версии** — падает поставляемый пример:

```
cd examples/multi-profile && envee trust && envee --profile prod resolve
[envee] ERROR [E008]: required variable not defined
[envee]     profile: ?
[envee]     variable: DATABASE_URL
```

При том что `[profiles.prod.env]` в том же файле задаёт `DATABASE_URL`.
Возможность `required` в связке с профилем нерабочая целиком.

Попутно: в контекст ошибки уходит литерал `"?"` вместо имени профиля
(`errs.RequiredVar(name, "?")`), и пользователь видит `profile: ?`.

**В Zig** проверка перенесена в конец, после файлов, профиля, `[env]`,
шаблонов и секретов; в диагностику кладётся настоящее имя профиля. Покрыто
тестами `required is satisfied by the profile's own variables`,
`required is satisfied by a file and by the env table` и
`a genuinely missing required variable is still an error`.

**Дифференциал** `apply` на 21 конфиге: единственное расхождение с Go — этот
случай. Остальные 20 (все типы значений, `false`-снятие, порядок слоёв,
шаблоны и топологический порядок, профили, секреты, `_.path`, загрузка
json/toml/dotenv, `ENVEE_*`, циклы) совпадают полностью.

### ⚠️ Приоритет конфигов вывернут наизнанку (`internal/resolver/resolver.go`)

**Симптом.** `Discover` возвращает файлы от высшего приоритета к низшему, а
`LoadAll` сливает их так, что каждый следующий ПЕРЕЗАПИСЫВАЕТ предыдущий
(`MergeInto`: `for k, v := range src.Env { dst.Env[k] = v }`). Побеждает
файл с НИЗШИМ приоритетом.

**Проверено на живом коде** (v0.3.0, ветка main):

| Раскладка | Документировано | Фактически в Go |
|---|---|---|
| `envee.local.toml` + `envee.toml` + `envee.d/10-a.toml` | побеждает `envee.local.toml` | побеждает `envee.d/10-a.toml` |
| `mono/envee.toml` + `mono/services/api/envee.toml`, cwd = api | побеждает дочерний | побеждает корневой |

Второй случай ломает ровно тот сценарий монорепозитория, который
рекламируют README и `examples/monorepo/envee.toml` (его собственный
комментарий: «A child `envee.toml` takes priority over this one»).
Комментарий к `LoadAll` при этом сам себе противоречит: «later (higher
priority) wins» — но список идёт highest-first, значит later = LOWER.

**В Zig реализовано документированное поведение**: побеждает файл с высшим
приоритетом, слияние идёт вперёд по списку с семантикой «первый записавший
выигрывает». Списочные директивы по-прежнему склеиваются в порядке
обнаружения — для `_.path` это существенно, его элементы уходят в начало
`$PATH` в том же порядке. Покрыто тестами `the higher-priority file wins` и
`a child config wins over its parent` в `src/resolver.zig`.

**Следствие для parity (шаги 15–17):** на конфигах из НЕСКОЛЬКИХ файлов
вывод `eval` у Go и Zig будет расходиться, и это ожидаемо. Сверять такие
случаи побайтно нельзя — либо ограничить parity одиночными конфигами, либо
сначала починить Go. Решить в шаге 15.

**Чинить ли Go отдельно** — решение владельца. Правка на стороне Go: в
`LoadAll` слить в обратном порядке либо в `MergeInto` не перезаписывать уже
заданные ключи; и то и другое меняет поведение выпущенной версии.


- README: пути `~/.local/share/envee/...` верны только для Linux; на macOS это `~/Library/Application Support/envee/...`. Исправить в README на шаге 23.
- `config/parse.go`: TODO про line/col в ошибках парсинга — в Zig сделать сразу (шаг 10).
- `template/template.go`: шапка пакета обещает фильтры `json` и `base64`, но `applyFilter` их не реализует — на них возвращается «unknown filter». Zig повторяет ПОВЕДЕНИЕ (ошибка), не документацию. На шаге 23 решить: реализовать оба фильтра или убрать из doc-комментария и ADR-0011.
