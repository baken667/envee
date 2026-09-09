# Architecture Decision Records (ADRs)

Этот каталог содержит **20 ADR'ов**, описывающих ключевые архитектурные решения проекта envee.

## Конвенция

Каждый ADR — отдельный файл `NNNN-title.md`, где:
- `NNNN` — монотонно растущий 4-значный номер.
- `title` — короткое kebab-case описание.

**Шаблон**: `template.md` в этом каталоге.

**Статусы**: `Proposed` → `Accepted` → `Deprecated` / `Superseded by NNNN`.

## Список ADR

| # | Тема | Статус |
|---|---|---|
| [0001](0001-language-go.md) | Язык реализации — Go | Superseded by 0019 |
| [0002](0002-config-format-toml.md) | Формат конфига — TOML 1.0 | Accepted |
| [0003](0003-naming-files.md) | Имена файлов и поисковая семантика | Accepted |
| [0004](0004-trust-model.md) | Trust model — content-hash + opt signature | Accepted |
| [0005](0005-shell-hooks.md) | Shell hooks — генерация per-shell | Accepted |
| [0006](0006-sandbox-wasm.md) | Sandbox для script layer — WASM | Accepted |
| [0007](0007-plugin-protocol.md) | Plugin protocol — exec-based JSON-over-stdio | Accepted |
| [0008](0008-daemon-protocol.md) | Daemon — опциональный, через UNIX socket | Accepted |
| [0009](0009-secret-handling.md) | Secrets — плагинная модель + OS keyring | Accepted |
| [0010](0010-profiles.md) | Профили — декларативные overlays | Accepted |
| [0011](0011-template-engine.md) | Template engine — минимальный Jinja-lite | Accepted |
| [0012](0012-cross-platform.md) | Cross-platform — macOS/Linux first-class | Accepted |
| [0013](0013-migration-from-envrc.md) | Миграция с .envrc | Accepted |
| [0014](0014-homebrew-distribution.md) | Homebrew distribution — custom tap | Accepted |
| [0015](0015-versioning.md) | Versioning — SemVer strict | Accepted |
| [0016](0016-logging.md) | Logging & observability | Accepted |
| [0017](0017-error-ux.md) | Error UX — actionable messages | Accepted |
| [0018](0018-cli-surface.md) | CLI surface — cobra-based | Accepted (cobra → свой разбор, см. 0019) |
| [0019](0019-language-zig.md) | Язык реализации — Zig, переписывание с Go | Accepted |
| [0020](0020-canonical-hash-v2.md) | Канонический хеш v2 и миграция хранилища доверия | Accepted |

## Связи между ADR'ами

```
ADR-019 (Zig) ─┬──> ADR-001 (Go) — superseded
               └──> ADR-020 (Hash v2) ──> ADR-004 (Trust)

ADR-001 (Go) ──┬──> ADR-007 (Plugin protocol)
               ├──> ADR-008 (Daemon)
               ├──> ADR-011 (Template)
               ├──> ADR-012 (Cross-platform)
               └──> ADR-018 (CLI)

ADR-002 (TOML) ──> ADR-003 (Naming) ──> ADR-010 (Profiles)
              └─> ADR-011 (Templates)

ADR-003 (Naming) ──> ADR-013 (Migration)

ADR-004 (Trust) ──> ADR-009 (Secrets)
               └─> ADR-013 (Migration)

ADR-005 (Hooks) ──> ADR-008 (Daemon)
              └─> ADR-017 (Error UX)

ADR-006 (WASM) ──> ADR-007 (Plugins)
              └─> ADR-009 (Secrets)

ADR-014 (Homebrew) ──> ADR-012 (Cross-platform)
                  └─> ADR-015 (Versioning)
```

## Принятые решения (TL;DR)

1. **Zig 0.16** для всего ядра (ADR-0019; до 0.4.0 — Go 1.24+).
2. **TOML 1.0** как primary config format.
3. **`envee.toml`** + `envee.local.toml` + `envee.d/*.toml` — naming.
4. **Trust через sha256(canonical content)**, опционально ed25519 signature; канонический вид v2 — ADR-0020.
5. **Shell hooks** генерируются per-shell (~50 строк), `envee init <shell>`.
6. **WASM (wazero)** для опционального script layer.
7. **Plugin protocol** — exec-based JSON-over-stdio.
8. **Daemon** опциональный через UNIX socket, lazy-start.
9. **Secrets** — плагинная модель, OS keyring cache, redact по умолчанию.
10. **Профили** — inline `[profiles.X]` + опционально `envee.X.toml`.
11. **Template engine** — минимальный, `{{ var | filter }}` синтаксис.
12. **Cross-platform** — macOS/Linux Tier 1, Windows Phase 3.
13. **Migration** — `envee import` + compatibility mode.
14. **Homebrew** — custom tap, GoReleaser, bottles, cosign.
15. **Versioning** — SemVer strict, pre-1.0 fast churn.
16. **Logging** — `log/slog`, structured, telemetry opt-in.
17. **Error UX** — severity + context + hint + doc.
18. **CLI** — cobra-подобная поверхность, собственный разбор аргументов, consistent UX.
