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
# До шага 15 у Zig-версии нет своего CLI, и `init` отдаёт временный envee-dev.
ZIG_BIN="$PWD/zig-out/bin/envee"
ZIG_DEV_BIN="$PWD/zig-out/bin/envee-dev"

if [[ "${1:-}" != "--no-build" ]]; then
  echo "==> building both implementations"
  make build >/dev/null
  zig build
fi

pass=0
fail=0

# normalize приводит вывод к виду, не зависящему от того, каким бинарём он
# получен: путь к самому бинарю и его каталог заменяются на плейсхолдеры.
normalize() {
  sed -e "s#${ZIG_DEV_BIN}#SELF#g" \
      -e "s#${ZIG_BIN}#SELF#g" \
      -e "s#${GO_BIN}#SELF#g" \
      -e "s#${PWD}#ROOT#g"
}

# check <name> <go-cmd...> -- <zig-cmd...>
check() {
  local name="$1"; shift
  local -a go_cmd=() zig_cmd=()
  while [[ "$1" != "--" ]]; do go_cmd+=("$1"); shift; done
  shift
  zig_cmd=("$@")

  local go_out zig_out go_rc zig_rc
  go_out="$("${go_cmd[@]}" 2>&1 | normalize)" && go_rc=0 || go_rc=$?
  zig_out="$("${zig_cmd[@]}" 2>&1 | normalize)" && zig_rc=0 || zig_rc=$?

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

# ---- init <shell> ----------------------------------------------------------
# Шаблоны hook'ов исполняются в оболочке пользователя, поэтому сверяются
# целиком и побайтно, а не по отдельным подстрокам.

for sh in bash zsh fish nu pwsh; do
  check "init $sh" "$GO_BIN" init "$sh" -- "$ZIG_DEV_BIN" init "$sh"
done

# ---- заготовки: включить по мере готовности шагов --------------------------
#
# Шаг 15 (eval) и шаг 17 (trust). Каждый бинарь получает собственный
# XDG_DATA_HOME, иначе они делят trust-store и сверка перестаёт быть честной.
#
# for ex in examples/*/; do
#   for sh in bash zsh fish nu pwsh; do
#     check "eval $sh $ex" \
#       env -i HOME="$HOME" PATH="$PATH" XDG_DATA_HOME=/tmp/envee-parity-go \
#         "$GO_BIN" --profile dev eval "$sh" \
#       -- \
#       env -i HOME="$HOME" PATH="$PATH" XDG_DATA_HOME=/tmp/envee-parity-zig \
#         "$ZIG_BIN" --profile dev eval "$sh"
#   done
# done
#
# Шаг 16 (resolve, check).
#
# for ex in examples/*/; do
#   check "resolve --json $ex" "$GO_BIN" resolve --json -- "$ZIG_BIN" resolve --json
#   check "check $ex" "$GO_BIN" check "$ex/envee.toml" -- "$ZIG_BIN" check "$ex/envee.toml"
# done
#
# Шаг 18: подпись, сделанная одной реализацией, обязана проверяться другой.

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
