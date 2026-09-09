#!/usr/bin/env bash
#
# Сверяет вывод Go- и Zig-реализаций envee.
#
# Пока идёт переписывание, Go-бинарь — эталон поведения. Любое расхождение
# здесь означает, что порт что-то потерял, и это надо чинить до следующего
# шага плана (docs/zig-rewrite-steps.md).
#
# Использование:
#   ./scripts/parity.sh          # собрать оба бинаря и сверить всё доступное
#   ./scripts/parity.sh --no-build
#
# Удалить на шаге 23 вместе с Go-реализацией.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

GO_BIN="$PWD/bin/envee"
ZIG_BIN="$PWD/zig-out/bin/envee"

if [[ "${1:-}" != "--no-build" ]]; then
  echo "==> building both implementations"
  make build >/dev/null
  zig build
fi

pass=0
fail=0

# normalize приводит вывод к виду, не зависящему от того, каким бинарём он
# получен: путь к самому бинарю и его каталог заменяются на плейсхолдеры.
#
# Хеш конфига тоже заменяется: канонический вид в Zig-версии свой, и хеши
# заведомо не совпадают (см. шаг 10 плана). Сверять по ним нечего, а вот
# всё остальное в сообщении сверять надо.
normalize() {
  sed -E -e "s#${ZIG_BIN}#SELF#g" \
         -e "s#${GO_BIN}#SELF#g" \
         -e "s#${PWD}#ROOT#g" \
         -e "s#sha256:[0-9a-f]{64}#sha256:HASH#g"
}

# Строка присваивания $PATH исключается из сравнения намеренно: Go дублирует
# в ней текущий PATH (см. «Найдено в Go»), и совпасть она не может. Что
# Zig-версия его НЕ дублирует, проверяется отдельно, ниже.
drop_path_line() {
  grep -v -E '^(export PATH=|set -gx PATH |\$env:PATH = )' || true
}

# Каталог, из которого запускаются обе команды. Меняется вокруг вызова
# check без подоболочки: в подоболочке счётчики pass/fail терялись, и итог
# врал «0 failed» при видимых FAIL.
CHECK_DIR="."

# check <name> <go-cmd...> -- <zig-cmd...>
check() {
  local name="$1"; shift
  local -a go_cmd=() zig_cmd=()
  while [[ "$1" != "--" ]]; do go_cmd+=("$1"); shift; done
  shift
  zig_cmd=("$@")

  local go_out zig_out go_rc zig_rc prev
  prev="$PWD"
  cd "$CHECK_DIR" || return 1
  go_out="$("${go_cmd[@]}" 2>&1 | normalize)" && go_rc=0 || go_rc=$?
  zig_out="$("${zig_cmd[@]}" 2>&1 | normalize)" && zig_rc=0 || zig_rc=$?
  cd "$prev" || return 1

  if [[ "$go_out" == "$zig_out" && "$go_rc" == "$zig_rc" ]]; then
    echo "ok   $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    if [[ "$go_rc" != "$zig_rc" ]]; then
      echo "     exit code: go=$go_rc zig=$zig_rc"
    fi
    diff <(printf '%s\n' "$go_out") <(printf '%s\n' "$zig_out") | sed 's/^/     /' | head -30 || true
    fail=$((fail + 1))
  fi
}

# check_no_path <name> <go-cmd...> -- <zig-cmd...>
#
# Как check, но без строки присваивания $PATH.
check_no_path() {
  local name="$1"; shift
  local -a go_cmd=() zig_cmd=()
  while [[ "$1" != "--" ]]; do go_cmd+=("$1"); shift; done
  shift
  zig_cmd=("$@")

  local go_out zig_out go_rc zig_rc prev
  prev="$PWD"
  cd "$CHECK_DIR" || return 1
  go_out="$("${go_cmd[@]}" 2>&1 | normalize | drop_path_line)" && go_rc=0 || go_rc=$?
  zig_out="$("${zig_cmd[@]}" 2>&1 | normalize | drop_path_line)" && zig_rc=0 || zig_rc=$?
  cd "$prev" || return 1

  if [[ "$go_out" == "$zig_out" && "$go_rc" == "$zig_rc" ]]; then
    echo "ok   $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    diff <(printf '%s\n' "$go_out") <(printf '%s\n' "$zig_out") | sed 's/^/     /' | head -30 || true
    fail=$((fail + 1))
  fi
}

# check_path_not_duplicated <name> <zig-cmd...>
#
# Go дописывает текущий $PATH в строку, которая его уже содержит, и он
# попадает туда дважды. Здесь проверяется, что Zig-версия так не делает.
check_path_not_duplicated() {
  local name="$1"; shift
  local prev out
  prev="$PWD"
  cd "$CHECK_DIR" || return 1
  out="$("$@" 2>/dev/null | grep -E '^export PATH=' || true)"
  cd "$prev" || return 1

  if [[ -z "$out" ]]; then
    echo "ok   $name (no PATH change)"
    pass=$((pass + 1))
  elif [[ "$out" == *"/usr/bin"* ]]; then
    echo "FAIL $name: the current PATH is repeated in the assignment"
    echo "     $out"
    fail=$((fail + 1))
  else
    echo "ok   $name"
    pass=$((pass + 1))
  fi
}

# expect_diff <reason> <name> <go-cmd...> -- <zig-cmd...>
#
# Утверждает, что выводы РАЗЛИЧАЮТСЯ, и объясняет почему. Ожидаемое
# расхождение — такое же утверждение, как совпадение: если оно вдруг
# исчезло, значит либо Go починили, либо Zig сломали, и знать об этом надо.
expect_diff() {
  local reason="$1"; shift
  local name="$1"; shift
  local -a go_cmd=() zig_cmd=()
  while [[ "$1" != "--" ]]; do go_cmd+=("$1"); shift; done
  shift
  zig_cmd=("$@")

  local go_out zig_out prev
  prev="$PWD"
  cd "$CHECK_DIR" || return 1
  go_out="$("${go_cmd[@]}" 2>&1 | normalize | drop_path_line)" || true
  zig_out="$("${zig_cmd[@]}" 2>&1 | normalize | drop_path_line)" || true
  cd "$prev" || return 1

  if [[ "$go_out" != "$zig_out" ]]; then
    echo "xfail $name ($reason)"
    pass=$((pass + 1))
  else
    echo "FAIL $name: expected a difference ($reason), but the outputs now match"
    fail=$((fail + 1))
  fi
}

# check_contract <name> <go-cmd...> -- <zig-cmd...>
#
# Сверяет только то, на что опираются скрипты и shell-hook: код возврата и
# код ошибки envee. Полный текст сравнивать рано там, где одна из реализаций
# ещё не дописана, — иначе сверка ловит не расхождение, а незаконченность.
check_contract() {
  local name="$1"; shift
  local -a go_cmd=() zig_cmd=()
  while [[ "$1" != "--" ]]; do go_cmd+=("$1"); shift; done
  shift
  zig_cmd=("$@")

  local go_out zig_out go_rc zig_rc prev
  prev="$PWD"
  cd "$CHECK_DIR" || return 1
  go_out="$("${go_cmd[@]}" 2>&1 | grep -oE '\[E[0-9]{3}\]' | head -1)" && go_rc=0 || go_rc=$?
  zig_out="$("${zig_cmd[@]}" 2>&1 | grep -oE '\[E[0-9]{3}\]' | head -1)" && zig_rc=0 || zig_rc=$?
  cd "$prev" || return 1

  if [[ "$go_out" == "$zig_out" && "$go_rc" == "$zig_rc" ]]; then
    echo "ok   $name (code ${go_out:-none}, exit $go_rc)"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    echo "     go:  code=${go_out:-none} exit=$go_rc"
    echo "     zig: code=${zig_out:-none} exit=$zig_rc"
    fail=$((fail + 1))
  fi
}

# ---- init <shell> ----------------------------------------------------------
# Шаблоны hook'ов исполняются в оболочке пользователя, поэтому сверяются
# целиком и побайтно, а не по отдельным подстрокам.

for sh in bash zsh fish nu pwsh; do
  check "init $sh" "$GO_BIN" init "$sh" -- "$ZIG_BIN" init "$sh"
done

# ---- eval после одобрения --------------------------------------------------
# Главная сверка: то, что уезжает в оболочку пользователя. Каждому бинарю —
# своё XDG_DATA_HOME: хеши у них разные по устройству (канонический вид в
# Zig-версии свой, см. шаг 10), поэтому и одобрять каждый должен сам себя.
#
# Строка присваивания $PATH из сравнения исключена: Go дублирует в ней
# текущий PATH. Что Zig так не делает — отдельная проверка ниже.

GO_TRUST=/tmp/envee-parity-go
ZIG_TRUST=/tmp/envee-parity-zig
rm -rf "$GO_TRUST" "$ZIG_TRUST"

# examples/secrets читает секреты через envee-plugin-env. Плагин пока
# Go-версии (свой появится на шаге 20); он должен быть в PATH у обеих
# реализаций, а хранилище секретов у каждой своё — оно лежит рядом с
# хранилищем доверия в XDG_DATA_HOME, так что заполняем оба.
PLUGIN_DIR="$(mktemp -d)"
go build -o "$PLUGIN_DIR/envee-plugin-env" ./plugins/env
for bin_and_store in "$GO_BIN:$GO_TRUST" "$ZIG_BIN:$ZIG_TRUST"; do
  bin="${bin_and_store%%:*}"; store="${bin_and_store#*:}"
  for kv in DATABASE_PASSWORD=hunter2 GITHUB_TOKEN=ghp_parity AWS_DB_CREDS=creds; do
    XDG_DATA_HOME="$store" "$bin" secret set "$kv" >/dev/null 2>&1
  done
done
PLUGIN_PATH="/usr/bin:/bin:$PLUGIN_DIR"
# Тот же плагин, но на Zig (шаг 20): ядро любой реализации обязано
# резолвить секреты через любой из двух.
ZIG_PLUGIN_DIR="$(mktemp -d)"
cp "$PWD/zig-out/bin/envee-plugin-env" "$ZIG_PLUGIN_DIR/"
ZIG_PLUGIN_PATH="/usr/bin:/bin:$ZIG_PLUGIN_DIR"

for ex in examples/*/; do
  ( cd "$ex" && XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" trust --yes >/dev/null 2>&1 ) || true
  ( cd "$ex" && XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" trust --yes >/dev/null 2>&1 ) || true

  CHECK_DIR="$ex"
  check_path_not_duplicated "eval PATH is not duplicated $ex" \
    env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" eval bash

  for sh in bash zsh fish nu pwsh; do
    check_no_path "eval $sh $ex" \
      env -i HOME="$HOME" PATH="$PLUGIN_PATH" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" eval "$sh" \
      -- \
      env -i HOME="$HOME" PATH="$PLUGIN_PATH" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" eval "$sh"
  done

  # С профилем: у multi-profile от него зависит почти всё.
  case "$ex" in
    examples/multi-profile/)
      # Go проверяет required ДО применения переменных профиля и падает на
      # DATABASE_URL, который сам же и задаёт. См. «Найдено в Go».
      expect_diff "Go checks required before applying the profile" \
        "eval bash --profile prod $ex" \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" --profile prod eval bash \
        -- \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" --profile prod eval bash
      ;;
    *)
      check_no_path "eval bash --profile prod $ex" \
        env -i HOME="$HOME" PATH="$PLUGIN_PATH" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" --profile prod eval bash \
        -- \
        env -i HOME="$HOME" PATH="$PLUGIN_PATH" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" --profile prod eval bash
      ;;
  esac

  # resolve. Там, где конфиг объявляет profile = "...", Go его игнорирует:
  # он читает профиль только из флага и переменной окружения, в отличие от
  # eval. См. «Найдено в Go».
  case "$ex" in
    examples/basic/|examples/multi-profile/)
      expect_diff "Go resolve ignores profile= from the config" "resolve --json $ex" \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" resolve --json \
        -- \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" resolve --json
      ;;
    *)
      check "resolve --json $ex" \
        env -i HOME="$HOME" PATH="$PLUGIN_PATH" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" resolve --json \
        -- \
        env -i HOME="$HOME" PATH="$PLUGIN_PATH" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" resolve --json
      ;;
  esac
  CHECK_DIR="."
done

# ---- плагин env: крест-накрест ---------------------------------------------
# Go-ядро с Zig-плагином и Zig-ядро с Zig-плагином дают то же, что Go-ядро с
# Go-плагином. Хранилище секретов у плагина общее с ядром (XDG_DATA_HOME),
# так что подмена плагина ничего больше не меняет.

CHECK_DIR="examples/secrets"
for sh in bash fish; do
  check_no_path "Go core + Zig plugin: eval $sh" \
    env -i HOME="$HOME" PATH="$PLUGIN_PATH" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" eval "$sh" \
    -- \
    env -i HOME="$HOME" PATH="$ZIG_PLUGIN_PATH" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" eval "$sh"
  check_no_path "Zig core + Zig plugin: eval $sh" \
    env -i HOME="$HOME" PATH="$PLUGIN_PATH" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" eval "$sh" \
    -- \
    env -i HOME="$HOME" PATH="$ZIG_PLUGIN_PATH" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" eval "$sh"
done
check "Go core + Zig plugin: resolve --json" \
  env -i HOME="$HOME" PATH="$PLUGIN_PATH" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" resolve --json \
  -- \
  env -i HOME="$HOME" PATH="$ZIG_PLUGIN_PATH" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" resolve --json
# Ошибка плагина доходит до пользователя тем же текстом: секрет удалён,
# обязательный секрет не резолвится, и оба ядра называют код not_found.
for bin_and_store in "$GO_BIN:$GO_TRUST" "$ZIG_BIN:$ZIG_TRUST"; do
  bin="${bin_and_store%%:*}"; store="${bin_and_store#*:}"
  XDG_DATA_HOME="$store" "$bin" secret unset DATABASE_PASSWORD >/dev/null 2>&1
done
check "Zig core + Zig plugin: missing required secret" \
  env -i HOME="$HOME" PATH="$ZIG_PLUGIN_PATH" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" eval bash \
  -- \
  env -i HOME="$HOME" PATH="$ZIG_PLUGIN_PATH" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" eval bash
CHECK_DIR="."
rm -rf "$ZIG_PLUGIN_DIR"

# ---- подписи: крест-накрест ------------------------------------------------
# Подпись, сделанная одной реализацией, обязана проверяться другой. Это
# единственная проверка того, что подписываемые байты собираются одинаково.
# Хеши конфигов у реализаций разные, но импорт кладёт запись как есть, так
# что на проверку подписи это не влияет.

SIGN_DIR="$(mktemp -d)"
if ssh-keygen -q -t ed25519 -N "" -C "envee-parity" -f "$SIGN_DIR/id_ed25519" >/dev/null 2>&1; then
  CHECK_DIR="examples/basic"

  # Zig подписывает и экспортирует; Go проверяет и импортирует.
  ( cd examples/basic && XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" trust --sign --key "$SIGN_DIR/id_ed25519" --export "$SIGN_DIR/zig-signed.json" >/dev/null 2>&1 )
  if ( cd examples/basic && XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" trust --from "$SIGN_DIR/zig-signed.json" --public-key "$SIGN_DIR/id_ed25519.pub" >/dev/null 2>&1 ); then
    echo "ok   Go verifies a Zig-signed entry"; pass=$((pass + 1))
  else
    echo "FAIL Go verifies a Zig-signed entry"; fail=$((fail + 1))
  fi

  # Go подписывает и экспортирует; Zig проверяет и импортирует.
  ( cd examples/basic && XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" trust --sign --key "$SIGN_DIR/id_ed25519" --export "$SIGN_DIR/go-signed.json" >/dev/null 2>&1 )
  if ( cd examples/basic && XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" trust --from "$SIGN_DIR/go-signed.json" --public-key "$SIGN_DIR/id_ed25519.pub" >/dev/null 2>&1 ); then
    echo "ok   Zig verifies a Go-signed entry"; pass=$((pass + 1))
  else
    echo "FAIL Zig verifies a Go-signed entry"; fail=$((fail + 1))
  fi

  # А подделку обе отвергают.
  sed 's/"file_hash": "sha256:/"file_hash": "sha256:0/' "$SIGN_DIR/go-signed.json" > "$SIGN_DIR/forged.json"
  if ( cd examples/basic && XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" trust --from "$SIGN_DIR/forged.json" --public-key "$SIGN_DIR/id_ed25519.pub" >/dev/null 2>&1 ); then
    echo "FAIL Zig rejects a forged entry"; fail=$((fail + 1))
  else
    echo "ok   Zig rejects a forged entry"; pass=$((pass + 1))
  fi
  CHECK_DIR="."
else
  echo "skip signature cross-check (ssh-keygen unavailable)"
fi
rm -rf "$SIGN_DIR"

# ---- check -----------------------------------------------------------------
# check не требует доверия — его для того и запускают, ПЕРЕД одобрением, —
# поэтому сверяется полностью и побайтно.

for ex in examples/*/; do
  CHECK_DIR="$ex"
  for mode in "" "--strict" "--json"; do
    # shellcheck disable=SC2086
    check "check $mode $ex" "$GO_BIN" check $mode -- "$ZIG_BIN" check $mode
  done
  CHECK_DIR="."
done

# ---- заготовки: включить по мере готовности шагов --------------------------
#
# Шаг 17 (trust): сверять УСПЕШНЫЙ вывод eval для каждой оболочки и каждого
# примера, после `envee trust --yes` в обоих бинарях. Учесть, что на конфигах
# из нескольких файлов вывод разойдётся намеренно — в Zig исправлен порядок
# приоритета (см. «Найдено в Go»).
#
# Шаг 16 закрыт частично: `check` сверяется выше. `resolve --json` и `diff`
# требуют доверия, поэтому включаются вместе с шагом 17.

rm -rf "$PLUGIN_DIR"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
