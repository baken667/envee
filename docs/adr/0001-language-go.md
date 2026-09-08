# ADR-001: Язык реализации — Go (с перспективой Rust-порта hot-path)

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Заменяет**: —
- **Решает**: На каком языке писать envee core

## Контекст

Нужен single static binary CLI с минимальным startup time (< 10ms cold, < 1ms warm). Кросс-компиляция на linux/darwin/windows + ARM. Команда в основном Go-familiar, есть и Rust.

## Решение

**Go 1.24+** для всего envee, кроме WASM-runtime.

### Подробное обоснование

| Критерий | Go | Rust | Verdict |
|---|---|---|---|
| Startup cold | ~3-5ms | ~0.5-2ms | Rust быстрее, но Go в пределах бюджета |
| Размер binary | 8-12 MB | 3-5 MB | Rust лучше, но не критично |
| Кросс-компиляция | `GOOS/GOARCH` built-in, goreleaser готов | `cross` + `cargo-zigbuild` — OK, но дольше | Go +1 |
| Зрелость экосистемы | `fsnotify`, `BurntSushi/toml`, `spf13/cobra` — mature | `notify`, `toml-rs`, `clap` — тоже mature | Паритет |
| Скорость разработки MVP | Высокая | Средняя | Go +2 (в 1.5-2× быстрее) |
| Recruitability | Go devs больше | Меньше | Go +1 |
| Sandboxing (WASM) | `wazero` — pure Go, zero cgo | `wasmtime` — cgo либо rust-only | Go +1 (no cgo = проще build) |
| Concurrency model | goroutines (нужны для daemon, watch) | tokio/async (тоже норм) | Паритет |
| Error handling | explicit, шумно | Result + `?` | Rust +0.5 |
| Стоимость бага | garbage collector может дать паузу | zero-cost, нет GC | Rust +0.5 для latency-critical |

**Суммарно**: Go выигрывает с заметным отрывом для нашего сценария.

### Что НЕ пишем на Go

- **WASM-движок** встроенный через `wazero` (pure-Go WASM runtime, MIT). Пользовательские `.wasm` скрипты — пишутся на чём угодно.
- **Bash stdlib** (50-100 строк на shell) — естественно, на bash.
- **Homebrew formula / Scoop manifest / deb package** — Ruby / PowerShell / Debian tools соответственно.

### Условия возможной миграции на Rust

Если после MVP профайлинг покажет, что **наша** latency > 5ms cold, переписываем ТОЛЬКО:
1. `internal/shell` (Export/Unset/Escape) — горячий путь при eval.
2. `internal/env` (diff, merge) — горячий путь.

CLI scaffolding, config layer, plugin SDK, daemon — остаются на Go. Это возможно потому, что `internal/shell` и `internal/env` — pure functions без side-effects, легко портируются.

### Почему не Rust-only

- 4-6 недель MVP на Go → 8-12 недель на Rust (с учётом написания cargo-эквивалентов нашего CI).
- Меньше людей, способных поддерживать.
- Экосистема CLI (cobra/pflag/viper) — Go-native, Rust-альтернативы (clap + figment + structopt) — рабочие, но менее зрелые.

## Последствия

### Положительные

- Быстрый MVP.
- Лёгкий найм контрибьюторов.
- Зрелая инфраструктура (goreleaser, Homebrew, Scoop, deb/rpm шаблоны).
- Single static binary через `CGO_ENABLED=0`.

### Отрицательные

- GC-паузы теоретически возможны (на практике 0.5-2ms, не критично).
- Размер бинаря 8-12 MB (приемлемо).
- Чуть медленнее Rust на горячих путях (компенсируем inotify-cache и daemon).

### Нейтральные

- `internal/` пакеты можно будет переиспользовать из Rust-порта через CGO или WASM.

## Заметки для будущих ревизий

- ADR будет пересмотрен, если:
  - Бенчмарки покажут cold-path > 5ms на типичном .envee.toml.
  - Потребуется fine-grained sandboxing (тогда WASM-движок уедет в C/Rust extension).
  - Memory usage > 30 MB в daemon-режиме (сейчас ожидание < 20 MB).
