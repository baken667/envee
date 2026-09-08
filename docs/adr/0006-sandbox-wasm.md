# ADR-006: Sandbox для script layer — WASM (Wazero), опционально

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как безопасно позволить пользователю писать логику в `.envee.toml`, не давая ему RCE

## Контекст

У direnv `.envrc` — это bash. Это **фича** (мощно) и **баг** (RCE, slow, hard to test).

Хотим:
- Default: декларативный TOML (без исполнения произвольного кода).
- Opt-in: возможность писать логику (compute timestamp, derive JWT, fetch metadata) — но в **sandbox**, без доступа к файлам за пределами `config_root`, без сети, с CPU quota.
- Опции sandbox: WASM, Lua (sandboxed), Rhai, WASI-only bash, restricted Python.

## Решение

**WASM** через `wazero` (pure Go, MIT, zero cgo).

`_.script` в `envee.toml`:

```toml
[env]
# Static value, декларативно
GREETING = "hello"

# Computed через WASM
TIMESTAMP = { script = "./scripts/timestamp.wasm", input = "now" }

# Conditional logic
NODE_ENV = { script = "./scripts/env-by-profile.wasm", input = { profile = "dev" } }
```

### Скрипт на Rust → WASM

```rust
// scripts/timestamp.rs
// cargo build --target wasm32-wasi --release
#![no_std]
#![no_main]

use core::ffi::{c_char, CStr};

#[no_mangle]
pub unsafe extern "C" 
fn _start() -> ! {
    // Entry point: read input from host via envee_get_input()
    let mut buf = [0u8; 1024];
    let len = envee_get_input(buf.as_mut_ptr(), buf.len());
    let input = core::str::from_utf8_unchecked(&buf[..len]);
    
    // Parse input (JSON-like, наш минимальный формат)
    // {"now": "2026-09-08T09:30:21Z"}
    
    // Compute
    let output = format!("\"timestamp\": \"{}\"", input);
    
    // Write to output buffer
    envee_set_output(output.as_ptr(), output.len());
    
    // Exit cleanly
    envee_exit(0);
    loop {}
}

extern "C" {
    fn envee_get_input(buf: *mut u8, cap: usize) -> usize;
    fn envee_set_output(buf: *const u8, len: usize);
    fn envee_exit(code: i32);
}
```

**Compile**: `rustup target add wasm32-wasi && cargo build --target wasm32-wasi --release`.

### Host imports (capabilities)

Скрипту доступны **только** эти функции:

| Import | Purpose | Permission |
|---|---|---|
| `envee.get_input(buf, cap) -> len` | Прочитать входные данные (JSON) | always |
| `envee.set_output(buf, len)` | Записать результат (JSON patches) | always |
| `envee.getenv(name_ptr, name_len, out_ptr, out_cap) -> out_len` | Прочитать env var | opt-in via `allow_env` |
| `envee.read_file(path_ptr, path_len, out_ptr, out_cap) -> out_len` | Прочитать файл | default: только в `config_root` |
| `envee.log(msg_ptr, msg_len, level: i32)` | Structured log | always |
| `envee.now() -> i64` | Unix timestamp | always |
| `envee.exit(code: i32)` | Завершить скрипт | always |

**Что НЕ доступно**:
- ❌ Network (no sockets, no HTTP, no DNS).
- ❌ Spawn processes.
- ❌ File writes (read-only FS).
- ❌ System calls beyond stdio/wasi-abi minimal.
- ❌ Wall clock modification, env modification.

### Quotas

| Resource | Default | Override |
|---|---|---|
| CPU time | 100ms | `quota_cpu = "500ms"` в metadata |
| Memory | 64 MB | `quota_memory = "128MiB"` |
| Fuel (WASM instructions) | 10^9 | `quota_fuel = "5e9"` |
| File reads | 100 | `quota_reads = 50` |
| File bytes total | 1 MB | `quota_bytes = "10MiB"` |
| WASM modules | 1 | (не переопределяется в v1) |

При превышении quota — `envee` возвращает `ErrScriptQuotaExceeded`, eval fallback на пустое значение для этой переменной (или hard error, если `required = true`).

### Script metadata (in TOML)

```toml
[env]
TIMESTAMP = {
  script = "./scripts/timestamp.wasm",
  allow_env = ["USER", "HOME"],
  allow_read = ["./secrets.json", "{{config_root}}/data/**"],
  quota_cpu = "200ms",
  quota_memory = "128MiB",
}
```

**Validation в `envee check`**:
- Все `allow_*` пути должны быть внутри `config_root` (или явно `../external` с warning).
- Все `script` файлы должны существовать.
- `quota_*` должны быть валидными (positive, parseable).

## Альтернативы, которые рассмотрели

### Lua sandboxed (Lua + custom metatables)

**Плюсы**: маленький runtime, быстрый, знакомый язык.

**Минусы**:
- Сложнее гарантировать sandbox (Lua C API → escape через metatable abuse).
- Требует cgo для `lua` C library (или pure-Go `gopher-lua` — медленнее, не 1:1).
- Не даёт portability guarantee (compiled binary x86 не запустится на ARM).

**Вердикт**: отвергнут. WASM лучше изолирует.

### Rhai (embedded Rust scripting)

**Плюсы**: Rust-native, простой синтаксис, можно делать sandbox.

**Минусы**:
- Sandbox Rhai не bullet-proof (есть known escapes через `eval`).
- Привязка к Rust-экосистеме (если кто-то пишет envee-порт на Go — нет Rhai).
- Не решает portability.

**Вердикт**: отвергнут.

### Restricted bash (bash + seccomp + namespaces)

**Плюсы**: user уже знает bash, не нужна новая abstraction.

**Минусы**:
- Seccomp/namespace настройка **очень** платформо-зависима.
- macOS не имеет namespaces (есть sandbox-exec, но он deprecated).
- Bash syntax позволяет тривиальный escape через `eval`, `printf`, etc.
- Тестировать sandbox — ад.

**Вердикт**: отвергнут. Это путь mise (нет sandbox, пользователь отвечает за содержимое `.mise.toml`).

### JS / Wasm via QuickJS

**Плюсы**: знакомый язык, QuickJS очень small.

**Минусы**:
- QuickJS WASM-порты — slower, чем wazero + native WASM.
- Меньше tooling для сборки.

**Вердикт**: возможно в v2.x, не в MVP.

### Starlark (Bazel's Python subset)

**Плюсы**: deterministic, sandboxed by design, Python-like.

**Минусы**:
- Меньше людей знают.
- Нет native `func` definitions в `envee.toml` через Starlark — нужно .star файлы.

**Вердикт**: альтернатива для v2.x.

## Почему WASM (wazero)

| Критерий | WASM (wazero) | Lua | Rhai | Restricted bash |
|---|---|---|---|---|
| Sandbox guarantee | ✅ Strong (WASI + capability imports) | ⚠️ Medium (escape-prone) | ⚠️ Medium | ❌ Weak |
| Portability across archs | ✅ Compile once, run anywhere | ⚠️ Build per arch | ⚠️ Per arch | ❌ Per arch |
| Language choice for user | ✅ Any (Rust, Go, C, Zig, AssemblyScript) | ⚠️ Lua only | ⚠️ Rhai only | ⚠️ Bash only |
| Cold start | ~5ms (wazero compile + instantiate) | < 1ms | ~10ms (JIT warmup) | ~20ms (bash startup) |
| cgo required | ❌ (wazero pure Go) | Depends | ❌ | ❌ |
| Hot reload of script | ✅ Re-instantiate | ✅ Reload | ✅ Reload | ❌ Subshell each time |
| Tooling (editor support) | ✅ rust-analyzer, etc. | ✅ | ⚠️ | ✅ |
| Test framework | ✅ Native WASM test | ✅ | ✅ | ⚠️ bats |
| Community size | ✅ Massive | ✅ Big | ⚠️ Niche | ✅ Huge |
| Our dependency size | +1.5 MB binary | +1 MB | +3 MB | 0 |

**Вердикт**: WASM выигрывает по sandbox guarantee и portability, приемлем по startup.

## Wazero integration

```go
// internal/script/wasm.go
package script

import (
    "context"
    "github.com/tetratelabs/wazero"
    "github.com/tetratelabs/wazero/api"
    "github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
)

type WasmRunner struct {
    runtime wazero.Runtime
    ctx     context.Context
    quotas  Quotas
}

func NewWasmRunner(quotas Quotas) (*WasmRunner, error) {
    ctx := context.Background()
    rt := wazero.NewRuntimeWithConfig(ctx, wazero.NewRuntimeConfig().
        WithCloseOnContextDone(true),
    )
    wasi_snapshot_preview1.Instantiate(ctx, rt)
    return &WasmRunner{runtime: rt, ctx: ctx, quotas: quotas}, nil
}

func (r *WasmRunner) Run(moduleBytes []byte, input []byte) (output []byte, err error) {
    ctx, cancel := context.WithTimeout(r.ctx, r.quotas.CPU)
    defer cancel()
    
    config := wazero.NewModuleConfig().
        WithName("envee-script").
        WithSysNanotime().       // нужен для std::time в Rust
        WithRandSource(...).     // НЕ передаём crypto/rand host source — пусть WASM свой
        WithFS(r.fsConfig).      // read-only mount config_root
        WithStartFunctions("_start")
    
    mod, err := r.runtime.InstantiateModuleWithConfig(ctx, moduleBytes, config)
    if err != nil { return nil, err }
    defer mod.Close(ctx)
    
    // Set input
    _, err = mod.ExportedFunction("envee_set_input").Call(ctx, ...)
    if err != nil { return nil, err }
    
    // Run
    _, err = mod.ExportedFunction("_start").Call(ctx)
    if err != nil { return nil, err }
    
    // Get output
    // ...
}
```

## Script SDK (helper crate)

`github.com/baken667/envee-script-sdk` — Rust crate с удобным API:

```rust
use envee_script_sdk::{envee_input, envee_output, EnveeValue};

#[no_mangle]
pub fn _start() {
    let input: serde_json::Value = envee_input().parse().unwrap();
    let result = match input["type"].as_str() {
        Some("now") => EnveeValue::String(chrono::Utc::now().to_rfc3339()),
        Some("from-file") => {
            let path = input["path"].as_str().unwrap();
            let content = std::fs::read_to_string(path).unwrap();
            EnveeValue::String(content)
        },
        _ => EnveeValue::Null,
    };
    envee_output(&result).unwrap();
}
```

В Go-экосистеме — `github.com/baken667/envee-script-sdk-go` (тоже есть).

## v1.x scope

- ✅ Wazero embedded, host imports.
- ✅ Default quotas.
- ✅ Per-script metadata override.
- ✅ Rust SDK (`envee-script-sdk`).
- ❌ Multi-module composition (только один script per variable).
- ❌ Async scripts (всё sync).
- ❌ Caching of compiled modules (в MVP — recompile on each eval, ~5ms hit).

**v2.x**: AOT caching, Go SDK, JS-via-QuickJS как альтернатива.

## Последствия

### Положительные

- Default TOML — без RCE, без overhead.
- Opt-in WASM — безопасно (sandbox), но мощно.
- User может писать скрипты на **любом** языке с WASM-target.
- Testable: WASM-модули можно тестировать standalone.

### Отрицательные

- Cold path +5ms на первое выполнение скрипта.
- 1.5 MB binary overhead (wazero embedded).
- User должен выучить минимальный WASM-host-ABI (но SDK скрывает это).

### Нейтральные

- WASM компилируется на разных toolchain'ах (rustc, Go, AssemblyScript) — наша задача — нормализовать output через host-ABI.
- AOT caching отложен в v2.x.
