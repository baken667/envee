# ADR-005: Shell hooks — генерация per-shell, минимальный runtime в shell

- **Статус**: Accepted
- **Дата**: 2026-09-08
- **Решает**: Как envee встраивается в bash/zsh/fish/nu/pwsh без overhead

## Контекст

Direnv и quickenv подходят к shell-интеграции по-разному:
- **direnv**: на каждый `PROMPT_COMMAND` вызывает `direnv export bash` (~5-15ms), eval'ит результат.
- **quickenv**: вообще без hook'а, ручной `quickenv reload && eval "$(quickenv vars)"`.

У обоих подходов проблемы:
- Direnv платит fork+exec на каждый prompt.
- Quickenv забывает про автоматизацию.

## Решение

**Гибридная архитектура**:
1. **Shell hook** минимальный, написан на native shell code, не делает `eval` в common case.
2. **Кеширование**: hook проверяет mtime `envee.toml` (через stat, не exec) и сравнивает с кешированным значением. Если совпадает — `eval "$(envee eval $SHELL)"` всё равно вызывается, но он **hot-path** (см. ниже).
3. **Hot path**: `envee eval $SHELL` без daemon — 1-2 stat() + diff в Go + printf. С daemon — UNIX socket call, O(100µs).

### Минимальный bash hook (выхлоп `envee init bash`)

```bash
# Этот код генерируется программой `envee init bash` (~50 строк)
# Кешируется пользователем, см. ниже.

_envee_hook() {
  local previous_exit_status=$?
  local previous_env="${_ENVEE_OLD:-}"
  local current_env
  
  # Fast path: cached, no daemon
  if [[ -z "${ENVEE_DAEMON_SOCK:-}" ]]; then
    # stat check — exit 0 если изменилось
    "$ENVEE_BIN" needs-reload --quiet && {
      local out
      out="$("$ENVEE_BIN" eval bash 2>/dev/null)"
      local rc=$?
      if [[ $rc -eq 0 && -n "$out" ]]; then
        eval "$out"
        export _ENVEE_OLD="$current_env"  # unused, just bookkeeping
      elif [[ $rc -ne 0 ]]; then
        # Не спамим в prompt — тихий fail
        return 0
      fi
    }
  else
    # Daemon mode: IPC call
    local out
    out="$("$ENVEE_BIN" --daemon eval bash 2>/dev/null)"
    # ... то же самое
  fi
  
  return $previous_exit_status
}

# Re-entrant guard: PROMPT_COMMAND может вызываться внутри subshell
case ";${PROMPT_COMMAND[*]:-};" in
  *";_envee_hook;"*) ;;
  *) 
    if [[ "$(declare -p PROMPT_COMMAND 2>&1)" == "declare -a"* ]]; then
      PROMPT_COMMAND=(_envee_hook "${PROMPT_COMMAND[@]}")
    else
      PROMPT_COMMAND="_envee_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    fi
    ;;
esac
```

### Zsh hook (отличия)

```zsh
# chpwd_functions — вызывается на каждый cd, в отличие от precmd (на каждый prompt)
_envee_chpwd() {
  # Zsh-специфика: setopt LOCAL_OPTIONS ERR_EXIT
  setopt LOCAL_OPTIONS PIPE_FAIL
  # Тело то же, что в bash
}

autoload -U add-zsh-hook
add-zsh-hook chpwd _envee_chpwd
add-zsh-hook precmd _envee_precmd  # для случаев когда cd не меняет cwd (pushd, popd, etc.)
```

### Fish hook

```fish
# envee init fish
function _envee_hook --on-variable PWD
  # PWD изменён → проверим envee.toml
  set -l out (envvee eval fish 2>/dev/null)
  if test $status -eq 0 -a -n "$out"
    eval $out
  end
end

function _envee_prompt --on-event fish_prompt
  # На каждый prompt — проверим даже без cd (для external edits)
  _envee_hook
end
```

### Nushell hook

```nu
# envee init nu
$env.ENVEE_HOOK = {|
  let out = (^envee eval nu | complete)
  if $out.exit_code == 0 and ($out.stdout | str length) > 0 {
    nu -c $out.stdout
  }
}

$env.config = ($env.config | upsert hooks.env_change.PWD {|| $env.ENVEE_HOOK })
```

### PowerShell hook

```powershell
# envee init pwsh
function _envee_hook {
  $previous = $?
  $out = & envee eval pwsh 2>$null
  if ($LASTEXITCODE -eq 0 -and $out) {
    Invoke-Expression $out
  }
  $global:_envee_previous = $previous
}

# Register on prompt
if (-not (Get-Variable -Name _envee_registered -ErrorAction SilentlyContinue)) {
  Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action { _envee_hook } | Out-Null
  Set-Variable -Name _envee_registered -Value $true -Scope Global
}
```

## Fast path: `envee needs-reload`

Минимизируем работу в shell. Команда `envee needs-reload` возвращает exit code:
- `0` — нужно перезагрузить (mtime изменился, или новый trust, или daemon invalidated cache).
- `1` — нет изменений, **NO-OP**.

Реализация:
```go
// internal/shell/hook.go
func NeedsReload() (bool, error) {
    cacheKey := computeCacheKey()  // mtime + path + parent hashes
    cached, err := readCache()
    if err != nil || cached.Key != cacheKey {
        return true, nil
    }
    return false, nil
}
```

Это **O(1) syscalls** (2-3 stat'а), не делает `bash` exec. На Linux: < 0.5ms.

## Eval hot path: `envee eval $SHELL`

```go
// internal/cli/eval.go
func runEval(shellName string) error {
    env, err := resolver.Resolve()  // ~1-2ms cold
    if err != nil { return err }
    diff := currentShellEnv().Diff(env)  // ~0.5ms
    fmt.Print(diff.ToShell(shellName))   // ~0.1ms
    return nil
}
```

Output format (bash):
```bash
export DATABASE_URL='postgres://localhost/dev'
export PORT='5432'  # type: int
export _ENVEE_PROFILE='dev'
export PATH='/Users/alice/work/myproj/bin:/usr/local/bin:/usr/bin:/bin'
unset LEGACY_FLAG
```

**Escape**: используем наш `internal/shell.BashEscape` (портирован из direnv, проверен годами). Single-quote с заменой `'` на `'\''`.

## Что генерируется через `envee init`

Программа `envee init <shell>` выводит готовый hook на stdout. Пользователь делает:
```bash
# bash
echo 'eval "$(envee init bash)"' >> ~/.bashrc

# zsh
echo 'eval "$(envee init zsh)"' >> ~/.zshrc

# fish
echo 'envee init fish | source' >> ~/.config/fish/config.fish

# nu
echo 'envee init nu | save -f ~/.config/envman.nu; source ~/.config/envman.nu' >> ~/.config/nushell/config.nu
```

### Caching hook output

**Best practice** (рекомендуем в README):
```bash
# В .zshrc:
envee_cache="${XDG_CACHE_HOME:-$HOME/.cache}/envee-init.zsh"
if [[ ! -f $envee_cache ]] || [[ "$(command -v envee)" -nt $envee_cache ]]; then
  envee init zsh > "$envee_cache"
fi
source "$envee_cache"
```

Это убирает `envee init` со startup'а shell. Плагин `oh-my-zsh` `envee` будет делать это автоматически.

## Per-shell limitations

| Shell | Hook mechanism | Caveats |
|---|---|---|
| bash | `PROMPT_COMMAND` | Работает отлично, никаких caveats. |
| zsh | `chpwd_functions` + `precmd_functions` | Двойной trigger — ок, dedup через state. |
| fish | `--on-variable PWD` + `fish_prompt` | Может вызываться 2-3 раза подряд; dedup. |
| nu | `hooks.env_change.PWD` | Работает, но nu-eval `nu -c` — overhead, кешируем строку. |
| pwsh | `Register-EngineEvent` | Overhead ~50ms на eval, рекомендуем **отключить** в PSReadLine и trigger manually. |
| elvish | `edit:after-command` hook | Поддерживается, но Elvish community small. |
| tcsh | `precmd` alias | Поддерживается через `shell_tcsh.go` (портировано из direnv). |

**MVP**: bash, zsh, fish. **Phase 2**: nu, pwsh. **Phase 3**: elvish, tcsh.

## De-duplication в hook'е

Чтобы hook не вызывал reload 3 раза подряд (один раз на cd, второй на prompt, третий на next prompt без cd), держим state:

```bash
# В shell hook
_ENVEE_LAST_HASH=""  # хеш последнего успешного env

if [[ "$_ENVEE_LAST_HASH" == "$(envee needs-reload --hash 2>/dev/null)" ]]; then
  return 0  # no change
fi
```

## Edge case: prompt в subshell

`(cd /tmp && pwd)` — subshell не должен триггерить reload. Поскольку hook ставится в `PROMPT_COMMAND`/`chpwd_functions`, он срабатывает только в interactive shell, не в subshell'ах.

## Edge case: nested shells

`bash → bash` — обе сессии имеют свой hook. Дочерний shell **не** наследует `DIRENV_*` / `_ENVEE_*` переменные автоматически (если только они не были `export`'нуты). Решение: **не** экспортим внутренний state.

## Производительность (target)

| Сценарий | Latency |
|---|---|
| `envee init bash` (cold, без cache) | < 5ms |
| `envee init bash` (cached) | 0ms (читается из файла) |
| `envee needs-reload` (no change) | < 0.5ms |
| `envee needs-reload` (changed) | 0.5ms (1 stat syscall + compare) |
| `envee eval bash` (cold, без daemon) | < 5ms |
| `envee eval bash` (warm, с daemon) | < 1ms |
| Total на prompt (no change) | < 0.5ms (только needs-reload) |
| Total на prompt (change) | < 6ms (needs-reload + eval) |

Сравнение с direnv:
- Direnv: ~5-15ms на **каждый** prompt (включая no-change).
- Envee: < 0.5ms на no-change prompt. **10-30× быстрее** в common case.

## Последствия

### Положительные

- Shell startup и prompt практически не замедляются.
- Hot path защищён `needs-reload` (только stat, не exec).
- Auto-reload при изменении файла (через mtime check на каждом prompt).
- Совместимо с tmux, screen, IDE-integrated terminals.

### Отрицательные

- Per-shell код (50 строк × 5 shells) — тестирование обязательно.
- Cache invalidation при изменении binary (`envee init > cache`) — нужно документировать.

### Нейтральные

- `envee init` в PATH должен быть при каждом shell startup. С кешем (best practice) — нет overhead.
- Daemon (опциональный) даёт ещё ~1-2ms speedup, но не критичен для UX.
