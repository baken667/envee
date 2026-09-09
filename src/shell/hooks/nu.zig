//! Hook-шаблон для nu.
//!
//! Содержимое перенесено байт в байт из Go-эталона
//! (internal/shell/shell.go, NuAdapter.Init) генератором, не руками:
//! этот код исполняется в оболочке пользователя, и опечатка здесь стоит
//! дорого. Плейсхолдер {{.SelfPath}} подставляется в shell.writeInit.

pub const init_template: []const u8 =
    \\# envee shell hook for nushell
    \\#
    \\# _envee_hook must be `def --env`: that is what lets load-env and hide-env
    \\# inside it affect your session. The hook below is registered as a string, not
    \\# a closure, for the same reason -- a closure would swallow the changes.
    \\def --env _envee_hook [] {
    \\  let r = (^"{{.SelfPath}}" --quiet eval nu | complete)
    \\  if $r.exit_code != 0 { return }
    \\  if ($r.stdout | str trim | is-empty) { return }
    \\  let d = ($r.stdout | from json)
    \\  for k in $d.unset { hide-env --ignore-errors $k }
    \\  $d.set | load-env
    \\}
    \\
    \\$env.config = ($env.config | upsert hooks.env_change.PWD [ "_envee_hook" ])
    \\
;
