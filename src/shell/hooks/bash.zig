//! Hook-шаблон для bash.
//!
//! Содержимое перенесено байт в байт из Go-эталона
//! (internal/shell/shell.go, BashAdapter.Init) генератором, не руками:
//! этот код исполняется в оболочке пользователя, и опечатка здесь стоит
//! дорого. Плейсхолдер {{.SelfPath}} подставляется в shell.writeInit.

pub const init_template: []const u8 =
    \\# envee shell hook for bash
    \\#
    \\# The hook runs on every prompt, so the common case -- nothing changed -- must
    \\# cost nothing. It compares the recorded dependency list against a stamp file
    \\# using only bash builtins: no fork, no subshell, no envee process. Invoking
    \\# envee costs about 4 ms; these comparisons are below measurement resolution.
    \\__envee_stamp="${TMPDIR:-/tmp}/envee-stamp.$$"
    \\__envee_deps=()
    \\
    \\_envee_apply() {
    \\  local out
    \\  out="$("{{.SelfPath}}" --quiet eval bash 2>/dev/null)"
    \\  if [[ $? -eq 0 && -n "$out" ]]; then
    \\    __envee_deps=()
    \\    eval "$out"
    \\    __envee_pwd="$PWD"
    \\    __envee_ok=1
    \\    # Truncate rather than touch: a redirection needs no external process.
    \\    : > "$__envee_stamp"
    \\  else
    \\    # Do not arm the fast path on failure. An untrusted directory must keep
    \\    # retrying, or 'envee trust' would not take effect until the next cd.
    \\    __envee_ok=
    \\  fi
    \\}
    \\
    \\_envee_hook() {
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
    \\case ";${PROMPT_COMMAND:-};" in
    \\  *";_envee_hook;"*) ;;
    \\  *)
    \\    if [[ "$(declare -p PROMPT_COMMAND 2>&1)" == "declare -a"* ]]; then
    \\      PROMPT_COMMAND=(_envee_hook "${PROMPT_COMMAND[@]}")
    \\    else
    \\      PROMPT_COMMAND="_envee_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    \\    fi
    \\    ;;
    \\esac
    \\
;
