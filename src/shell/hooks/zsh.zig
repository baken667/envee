//! Hook-шаблон для zsh.
//!
//! Содержимое перенесено байт в байт из Go-эталона
//! (internal/shell/shell.go, ZshAdapter.Init) генератором, не руками:
//! этот код исполняется в оболочке пользователя, и опечатка здесь стоит
//! дорого. Плейсхолдер {{.SelfPath}} подставляется в shell.writeInit.

pub const init_template: []const u8 =
    \\# envee shell hook for zsh
    \\#
    \\# See the bash hook for why the fast path exists: precmd fires on every
    \\# prompt, and invoking envee costs about 4 ms.
    \\__envee_stamp="${TMPDIR:-/tmp}/envee-stamp.$$"
    \\__envee_deps=()
    \\
    \\_envee_apply() {
    \\  local out
    \\  out="$("{{.SelfPath}}" --quiet eval zsh 2>/dev/null)"
    \\  if [[ $? -eq 0 && -n "$out" ]]; then
    \\    __envee_deps=()
    \\    eval "$out"
    \\    __envee_pwd="$PWD"
    \\    __envee_ok=1
    \\    : > "$__envee_stamp"
    \\  else
    \\    __envee_ok=
    \\  fi
    \\}
    \\
    \\_envee_chpwd() {
    \\  # Preserve the caller's exit status: this runs from the prompt, and a shell
    \\  # prompt that displays $? must not be told about envee's internals.
    \\  local __envee_last=$?
    \\  if [[ -n "$__envee_ok" && "$PWD" == "$__envee_pwd" ]]; then
    \\    local f
    \\    for f in "${__envee_deps[@]}"; do
    \\      if [[ "$f" -nt "$__envee_stamp" ]]; then
    \\        _envee_apply
    \\        return $__envee_last
    \\      fi
    \\    done
    \\    return $__envee_last
    \\  fi
    \\  _envee_apply
    \\  return $__envee_last
    \\}
    \\
    \\_envee_precmd() {
    \\  # Trigger on every prompt (for external edits); the guard above makes that
    \\  # cheap when nothing has changed.
    \\  _envee_chpwd
    \\}
    \\
    \\autoload -U add-zsh-hook
    \\add-zsh-hook chpwd _envee_chpwd
    \\add-zsh-hook precmd _envee_precmd
    \\
;
