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

# examples/secrets объявляет секреты, а разбор плагинов появится на шаге 19.
# До тех пор Zig подставляет заглушки там, где Go зовёт плагин и падает.
SECRETS_REASON="plugin dispatch lands in step 19"

for ex in examples/*/; do
  ( cd "$ex" && XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" trust --yes >/dev/null 2>&1 ) || true
  ( cd "$ex" && XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" trust --yes >/dev/null 2>&1 ) || true

  CHECK_DIR="$ex"
  check_path_not_duplicated "eval PATH is not duplicated $ex" \
    env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" eval bash

  for sh in bash zsh fish nu pwsh; do
    if [[ "$ex" == "examples/secrets/" ]]; then
      expect_diff "$SECRETS_REASON" "eval $sh $ex" \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" eval "$sh" \
        -- \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" eval "$sh"
    else
      check_no_path "eval $sh $ex" \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" eval "$sh" \
        -- \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" eval "$sh"
    fi
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
    examples/secrets/)
      expect_diff "$SECRETS_REASON" "eval bash --profile prod $ex" \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" --profile prod eval bash \
        -- \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" --profile prod eval bash
      ;;
    *)
      check_no_path "eval bash --profile prod $ex" \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" --profile prod eval bash \
        -- \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" --profile prod eval bash
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
    examples/secrets/)
      expect_diff "$SECRETS_REASON" "resolve --json $ex" \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" resolve --json \
        -- \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" resolve --json
      ;;
    *)
      check "resolve --json $ex" \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$GO_TRUST" "$GO_BIN" resolve --json \
        -- \
        env -i HOME="$HOME" PATH="/usr/bin:/bin" XDG_DATA_HOME="$ZIG_TRUST" "$ZIG_BIN" resolve --json
      ;;
  esac
  CHECK_DIR="."
done

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
# Шаг 18: подпись, сделанная одной реализацией, проверяется другой.

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
