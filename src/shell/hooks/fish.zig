//! Hook-шаблон для fish.
//!
//! Содержимое перенесено байт в байт из Go-эталона
//! (internal/shell/shell.go, FishAdapter.Init) генератором, не руками:
//! этот код исполняется в оболочке пользователя, и опечатка здесь стоит
//! дорого. Плейсхолдер {{.SelfPath}} подставляется в shell.writeInit.

pub const init_template: []const u8 =
    \\# envee shell hook for fish
    \\#
    \\# The hook fires on every prompt, so the common case -- nothing changed --
    \\# must cost nothing. It compares the recorded dependency list against a stamp
    \\# file using only fish builtins; invoking envee costs about 4 ms.
    \\#
    \\# 'string collect' below is load-bearing: command substitution in fish splits
    \\# output into a LIST on newlines, and eval joins a list with spaces, so
    \\# without it the generated statements arrive as one line and every variable
    \\# after the first lands in the first one's value.
    \\set -g __envee_stamp (test -n "$TMPDIR"; and echo $TMPDIR; or echo /tmp)/envee-stamp.(echo %self)
    \\set -g __envee_deps
    \\
    \\function _envee_apply
    \\  set -l out ("{{.SelfPath}}" --quiet eval fish 2>/dev/null | string collect)
    \\  if test $status -eq 0 -a -n "$out"
    \\    set -g __envee_deps
    \\    eval $out
    \\    set -g __envee_pwd $PWD
    \\    set -g __envee_ok 1
    \\    # Truncate rather than touch: no external process.
    \\    echo -n "" > $__envee_stamp
    \\  else
    \\    # Do not arm the fast path on failure, or 'envee trust' would not take
    \\    # effect until the next directory change.
    \\    set -e __envee_ok
    \\  end
    \\end
    \\
    \\function _envee_hook --on-variable PWD
    \\  # Preserve the caller's exit status: this runs from the prompt, and a prompt
    \\  # that displays $status must not be told about envee's internals.
    \\  set -l __envee_last $status
    \\  if set -q __envee_ok; and test "$PWD" = "$__envee_pwd"
    \\    for f in $__envee_deps
    \\      if test "$f" -nt "$__envee_stamp"
    \\        _envee_apply
    \\        return $__envee_last
    \\      end
    \\    end
    \\    return $__envee_last
    \\  end
    \\  _envee_apply
    \\  return $__envee_last
    \\end
    \\
    \\function _envee_prompt --on-event fish_prompt
    \\  _envee_hook
    \\end
    \\
;
