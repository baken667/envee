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
    diff <(printf '%s\n' "$go_out") <(printf '%s\n' "$zig_out") | sed 's/^/     /' | head -30
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

# ---- eval без доверия ------------------------------------------------------
# Хранилище доверия появится на шаге 17. До тех пор обе реализации обязаны
# одинаково ОТКАЗЫВАТЬ: код ошибки E001 и код возврата 3. Каждой даётся своё
# XDG_DATA_HOME, иначе они делят хранилище и сверка перестаёт быть честной.
#
# Полный текст здесь не сверяется по двум причинам, обе временные: у Go в
# сообщении есть строка CAUSE из хранилища, которого в Zig ещё нет, а хеш
# конфига в Zig-версии свой по устройству (шаг 10). После шага 17 сверять
# надо будет уже успешный вывод eval, а не отказ.

for ex in examples/*/; do
  CHECK_DIR="$ex"
  check_contract "eval bash (untrusted) $ex" \
    env -i HOME="$HOME" PATH="$PATH" XDG_DATA_HOME=/tmp/envee-parity-go \
      "$GO_BIN" eval bash \
    -- \
    env -i HOME="$HOME" PATH="$PATH" XDG_DATA_HOME=/tmp/envee-parity-zig \
      "$ZIG_BIN" eval bash
  CHECK_DIR="."
done

# ---- заготовки: включить по мере готовности шагов --------------------------
#
# Шаг 17 (trust): сверять УСПЕШНЫЙ вывод eval для каждой оболочки и каждого
# примера, после `envee trust --yes` в обоих бинарях. Учесть, что на конфигах
# из нескольких файлов вывод разойдётся намеренно — в Zig исправлен порядок
# приоритета (см. «Найдено в Go»).
#
# Шаг 16: `resolve --json` и `check` для всех примеров.
# Шаг 18: подпись, сделанная одной реализацией, проверяется другой.

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
