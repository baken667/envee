# ADR-008: Daemon — опциональный, через UNIX socket, lazy-start

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Опциональный long-running процесс для прогрева кеша и inotify-watcher

## Контекст

Hook в shell вызывается **на каждый prompt** (тысячи раз в день). Hot path в core — это:
- 1-3 stat() syscall на `envee.toml` + parent dirs.
- Парсинг TOML (если изменился).
- Diff computation.

С daemon можно:
- Следить за inotify-событиями на `envee.toml` (мгновенная инвалидация кеша).
- Держать parsed config в памяти.
- Кешировать resolved env для текущего cwd (invalidate на cd).
- IPC = single socket write, ~50µs.

Без daemon — каждый eval ~3-8ms. С daemon — ~0.5ms.

## Решение

**`enveed` daemon** (отдельный бинарь, `cmd/enveed/main.go`):
- UNIX socket в `$XDG_RUNTIME_DIR/envee.sock` (если нет `XDG_RUNTIME_DIR`, то `/tmp/envee-<uid>.sock`).
- Протокол: **MessagePack-RPC** через socket (compact, schema-validated, fast).
- Auto-start: первый `envee eval` запускает daemon через `os.Exec`, синхронно ждёт socket ready (max 200ms), затем IPC.
- Auto-shutdown: daemon exits если нет активности 30 минут.
- PID file: `$XDG_RUNTIME_DIR/envee.pid` для проверки что процесс жив.
- **Один daemon per user** (singleton через lock file).

## Жизненный цикл

```
[First envee call]
     │
     ▼
[envee checks $XDG_RUNTIME_DIR/envee.sock]
     │
     ├─ exists & connectable → use it
     │
     └─ not exists → enveed --foreground (или spawn)
                    │
                    ├─ Lock $XDG_RUNTIME_DIR/envee.lock
                    ├─ Bind UNIX socket
                    ├─ Start inotify watcher on $HOME/**/*.envee.toml
                    ├─ SIGTERM handler
                    └─ Idle timer (30 min)
```

```
[envee eval $SHELL] (subsequent calls)
     │
     ▼
[Send request to socket: {"op": "eval", "shell": "bash", "cwd": "..."}]
     │
     ▼
[daemon: inotify check → cache hit? → return cached diff]
     │                                              │
     │  cache miss                                   │
     ▼                                              │
[daemon: re-parse + resolve + diff]                  │
     │                                              │
     ▼                                              │
[Send response: {"diff": "export X='1';\n..."}]    │
     │                                              │
     ▼                                              ▼
[envee prints to stdout]
```

## Protocol (MessagePack-RPC)

**Request envelope**:

```go
type Request struct {
    Version   uint16   `msg:"v"`
    Op        string   `msg:"op"`         // "eval", "resolve", "status", "ping", "invalidate", "shutdown"
    ID        string   `msg:"id"`         // UUID v4
    Cwd       string   `msg:"cwd"`
    Shell     string   `msg:"shell,omitempty"`
    Profile   string   `msg:"profile,omitempty"`
    Timeout   uint32   `msg:"timeout_ms,omitempty"`
}
```

**Response envelope**:

```go
type Response struct {
    Version   uint16            `msg:"v"`
    ID        string            `msg:"id"`
    Status    string            `msg:"status"`  // "ok" | "error"
    Diff      string            `msg:"diff,omitempty"`     // for eval
    Env       map[string]string `msg:"env,omitempty"`      // for resolve
    Error     *Error            `msg:"error,omitempty"`
    ElapsedMs uint32            `msg:"elapsed_ms"`
}

type Error struct {
    Code    string `msg:"code"`
    Message string `msg:"message"`
    Detail  string `msg:"detail,omitempty"`
}
```

**Op semantic**:

| Op | Description | Latency target |
|---|---|---|
| `ping` | Health check | < 1ms |
| `eval` | Get shell-specific diff for cwd | < 1ms (cached) / < 50ms (cold) |
| `resolve` | Get full resolved env (no shell escape) | < 1ms (cached) / < 100ms (cold) |
| `status` | Daemon state (for `envee status`) | < 5ms |
| `invalidate` | Force cache invalidation for path | < 5ms |
| `shutdown` | Graceful exit | < 100ms |

## Inotify watcher

```go
// internal/daemon/watcher.go
type Watcher struct {
    fsnotifyWatcher *fsnotify.Watcher
    onChange        func(path string)
    debounce        time.Duration
}

func NewWatcher(debounce time.Duration) (*Watcher, error) {
    w, err := fsnotify.NewWatcher()
    if err != nil { return nil, err }
    return &Watcher{fsnotifyWatcher: w, debounce: debounce}, nil
}

func (w *Watcher) Watch(root string) error {
    // Walk home dir, find all envee.toml, add watch on dir + file
    return filepath.WalkDir(root, func(path string, d fsutil.DirEntry, err error) error {
        if err != nil { return err }
        if d.IsDir() {
            // Don't watch .git, node_modules, etc.
            if isIgnoredDir(d.Name()) { return fsutil.SkipDir }
            return w.fsnotifyWatcher.Add(path)
        }
        if isEnveeFile(d.Name()) {
            w.fsnotifyWatcher.Add(path)
        }
        return nil
    })
}

func (w *Watcher) Run(ctx context.Context, onChange func(path string)) {
    var lastEvent time.Time
    var pendingPath string
    
    for {
        select {
        case ev, ok := <-w.fsnotifyWatcher.Events:
            if !ok { return }
            if ev.Has(fsnotify.Write) || ev.Has(fsnotify.Create) || ev.Has(fsnotify.Remove) {
                lastEvent = time.Now()
                pendingPath = ev.Name
            }
        case <-time.After(100*time.Millisecond):
            if !pendingPath.IsEmpty() && time.Since(lastEvent) >= w.debounce {
                onChange(pendingPath)
                pendingPath = ""
            }
        case <-ctx.Done():
            return
        }
    }
}
```

**Debounce**: 100ms. Некоторые редакторы делают несколько write-событий на одно save (vim, VSCode с auto-format).

**Ignored dirs**: `.git`, `node_modules`, `target`, `dist`, `build`, `.venv`, `__pycache__`, `.idea`, `.vscode`, `vendor`.

**Recursive vs flat**: рекурсивно обходим `$HOME`, **но с cap** на depth (10) и total watch descriptors (5000 на Linux по дефолту). Если превышено — graceful degradation, fallback на polling.

## Cache

```go
// internal/daemon/cache.go
type Cache struct {
    mu      sync.RWMutex
    entries map[string]*CacheEntry
    ttl     time.Duration
}

type CacheEntry struct {
    Cwd        string
    ConfigHash string    // sha256 of merged config bytes
    ResolvedEnv Env
    Diff       map[string]DiffOp
    ComputedAt time.Time
}

func (c *Cache) Get(cwd string) (*CacheEntry, bool) {
    c.mu.RLock()
    defer c.mu.RUnlock()
    e, ok := c.entries[cwd]
    if !ok || time.Since(e.ComputedAt) > c.ttl {
        return nil, false
    }
    return e, true
}
```

**Cache key**: `cwd`. `ResolvedEnv` — уже в виде `map[string]string`.

**Cache invalidation triggers**:
- Inotify event на любом envee.toml в иерархии cwd.
- mtime change на `.envee.toml` (второй уровень защиты если inotify пропустил).
- `envee invalidate` команда.
- TTL expired (5 min default, не полагаемся только на это).

**Cache size**: ограничен LRU 1000 entries (по cwd). Memory < 10 MB.

**Cache persistence**: **не** персистим между daemon restart'ами. Cold start = full re-resolve, потом warmed up.

## Когда НЕ запускать daemon

1. **CI environment** (detect: `CI=true` env var). Прямой exec, без daemon.
2. **Container without persistent filesystem**. Socket создать нельзя → fallback.
3. **Frozen environment** (chroot, sandbox). Fallback.
4. **User explicitly disabled**: `ENVEE_NO_DAEMON=1` или `envee daemon disable`.

В этих случаях `envee` работает в **standalone mode**: каждый call — fresh resolve, без IPC. Latency выше, но работает.

## Когда daemon умирает / restart

- **Crash** (SIGSEGV): socket остаётся, но не connectable. Core пробует connect, fails, удаляет stale socket, spawns new daemon.
- **Graceful shutdown (SIGTERM)**: даем текущим request'ам 1 сек на завершение, потом exit.
- **Manual restart**: `envee daemon restart`.
- **System shutdown**: SIGTERM → exit.

## Auth / security

- UNIX socket имеет permissions `0600`, owner = current user.
- Через **абстрактный socket** на Linux (не привязан к FS) — гарантированно user-only.
- На macOS — обычный socket в `$XDG_RUNTIME_DIR` с strict permissions.

**Threat model**: тот же user может подключиться и сделать request. Это OK — envee работает в user context, нет multi-tenant model. Если user хочет защитить socket от других пользователей на shared system — должен использовать `ENVEE_NO_DAEMON=1`.

## Windows support (Phase 3)

- Named pipe вместо UNIX socket: `\\.\pipe\envee-<uid>`.
- fsnotify на Windows — `ReadDirectoryChangesW` через `fsnotify`.
- Permissions через DACL (только current user + SYSTEM).

## Последствия

### Положительные

- Latency `envee eval` warm: < 1ms (10× speedup vs standalone).
- Inotify — мгновенная инвалидация кеша при edit'е `envee.toml` в любом IDE.
- Standalone mode как fallback — работает везде.
- Singleton model — нет zombie processes.

### Отрицательные

- Дополнительная complexity (daemon, IPC, lifecycle).
- Daemon crash → на короткое время все calls в standalone mode.
- Windows: named pipe сложнее, чем UNIX socket.
- Debug: пользователь должен понимать, что есть фоновый процесс.

### Нейтральные

- Singleton model требует lock file (race condition handling).
- Resource limits (memory, file descriptors) — нужно явно лимитировать.
