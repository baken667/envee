// Package shell provides shell-specific adapters for emitting env changes.
//
// Each supported shell (bash, zsh, fish, nu, pwsh, ...) implements the
// Adapter interface, which knows how to format an env diff as commands
// the shell can eval.
//
// See docs/adr/0005-shell-hooks.md.
package shell

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// Name identifies a supported shell.
type Name string

const (
	Bash   Name = "bash"
	Zsh    Name = "zsh"
	Sh     Name = "sh"
	Fish   Name = "fish"
	Nu     Name = "nu"
	Pwsh   Name = "pwsh"
	Elvish Name = "elvish"
	Tcsh   Name = "tcsh"
)

// Detect returns the Adapter for a given shell name (case-insensitive).
// Returns nil if the shell is not supported.
func Detect(name string) Adapter {
	switch strings.ToLower(name) {
	case "bash", "sh":
		return BashAdapter{}
	case "zsh":
		return ZshAdapter{}
	case "fish":
		return FishAdapter{}
	case "nu", "nushell":
		return NuAdapter{}
	case "pwsh", "powershell":
		return PwshAdapter{}
	}
	return nil
}

// Adapter formats env diffs for a specific shell.
type Adapter interface {
	// Name returns the shell name (e.g., "bash").
	Name() Name

	// Init returns the shell hook code to be eval'd at shell startup.
	// The {{.SelfPath}} placeholder is replaced with the absolute path
	// to the envee binary.
	Init(selfPath string) string

	// Export returns a script that, when eval'd, sets the given key=value
	// in the shell. Value must already be escaped according to the shell's
	// rules.
	Export(key, value string) string

	// Unset returns a script that unsets the given key.
	Unset(key string) string

	// SetPath returns a script that updates $PATH to the given value
	// (colon-separated list of directories).
	SetPath(dirs []string) string

	// Escape returns the shell-safe representation of a string value.
	Escape(s string) string
}

// FormatDiff renders an env.Diff as a sequence of shell commands.
//
// Returns a string suitable for eval by the shell.
func FormatDiff(a Adapter, ops []DiffOp) string {
	var b strings.Builder
	for _, op := range ops {
		if op.Set {
			b.WriteString(a.Export(op.Key, op.Value))
			b.WriteByte('\n')
		} else {
			b.WriteString(a.Unset(op.Key))
			b.WriteByte('\n')
		}
	}
	return b.String()
}

// DiffOp mirrors env.DiffOp but is duplicated here to avoid an import cycle
// in tests that only need the shell layer.
type DiffOp struct {
	Key   string
	Set   bool
	Value string
}

// init registers all built-in adapters in a default registry.
func init() {
	// Reserved for future registry pattern.
}

// renderInitTemplate replaces {{.SelfPath}} with the given path.
//
// All adapters use the same template variable, so we centralize substitution.
func renderInitTemplate(tpl, selfPath string) string {
	return strings.ReplaceAll(tpl, "{{.SelfPath}}", selfPath)
}

// PathListSeparator is the separator for $PATH on the current OS.
//
// On Unix, ":". On Windows, ";". We use ":", consistent with bash/zsh conventions.
const PathListSeparator = ':'

// FormatPathValue formats a list of directories for $PATH assignment.
//
// Directories are joined with ':' and shell-escaped.
func FormatPathValue(dirs []string, escape func(string) string) string {
	escaped := make([]string, len(dirs))
	for i, d := range dirs {
		escaped[i] = escape(d)
	}
	return strings.Join(escaped, ":")
}

// ---- bash adapter ----------------------------------------------------------

// BashAdapter implements Adapter for bash (and POSIX sh).
type BashAdapter struct{}

// Name implements Adapter.
func (BashAdapter) Name() Name { return Bash }

// Init implements Adapter.
func (BashAdapter) Init(selfPath string) string {
	const tpl = `# envee shell hook for bash
#
# The hook runs on every prompt, so the common case -- nothing changed -- must
# cost nothing. It compares the recorded dependency list against a stamp file
# using only bash builtins: no fork, no subshell, no envee process. Invoking
# envee costs about 4 ms; these comparisons are below measurement resolution.
__envee_stamp="${TMPDIR:-/tmp}/envee-stamp.$$"
__envee_deps=()

_envee_apply() {
  local out
  out="$("{{.SelfPath}}" --quiet eval bash 2>/dev/null)"
  if [[ $? -eq 0 && -n "$out" ]]; then
    __envee_deps=()
    eval "$out"
    __envee_pwd="$PWD"
    __envee_ok=1
    # Truncate rather than touch: a redirection needs no external process.
    : > "$__envee_stamp"
  else
    # Do not arm the fast path on failure. An untrusted directory must keep
    # retrying, or 'envee trust' would not take effect until the next cd.
    __envee_ok=
  fi
}

_envee_hook() {
  # Preserve the caller's exit status: this runs from the prompt, and a shell
  # prompt that displays $? must not be told about envee's internals.
  local __envee_last=$?
  if [[ -n "$__envee_ok" && "$PWD" == "$__envee_pwd" ]]; then
    local f
    for f in "${__envee_deps[@]}"; do
      if [[ "$f" -nt "$__envee_stamp" ]]; then
        _envee_apply
        return $__envee_last
      fi
    done
    return $__envee_last
  fi
  _envee_apply
  return $__envee_last
}

case ";${PROMPT_COMMAND:-};" in
  *";_envee_hook;"*) ;;
  *)
    if [[ "$(declare -p PROMPT_COMMAND 2>&1)" == "declare -a"* ]]; then
      PROMPT_COMMAND=(_envee_hook "${PROMPT_COMMAND[@]}")
    else
      PROMPT_COMMAND="_envee_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    fi
    ;;
esac
`
	return renderInitTemplate(tpl, selfPath)
}

// Export implements Adapter.
func (BashAdapter) Export(key, value string) string {
	return "export " + key + "=" + value + ";"
}

// Unset implements Adapter.
func (BashAdapter) Unset(key string) string {
	return "unset " + key + " 2>/dev/null || true;"
}

// SetPath implements Adapter.
func (BashAdapter) SetPath(dirs []string) string {
	if len(dirs) == 0 {
		return ""
	}
	escaped := make([]string, len(dirs))
	for i, d := range dirs {
		escaped[i] = BashEscape(d)
	}
	return "export PATH=" + strings.Join(escaped, ":") + ":\"$PATH\";"
}

// Escape implements Adapter.
func (BashAdapter) Escape(s string) string {
	return BashEscape(s)
}

// ---- zsh adapter -----------------------------------------------------------

// ZshAdapter implements Adapter for zsh.
type ZshAdapter struct{}

// Name implements Adapter.
func (ZshAdapter) Name() Name { return Zsh }

// Init implements Adapter.
func (ZshAdapter) Init(selfPath string) string {
	const tpl = `# envee shell hook for zsh
#
# See the bash hook for why the fast path exists: precmd fires on every
# prompt, and invoking envee costs about 4 ms.
__envee_stamp="${TMPDIR:-/tmp}/envee-stamp.$$"
__envee_deps=()

_envee_apply() {
  local out
  out="$("{{.SelfPath}}" --quiet eval zsh 2>/dev/null)"
  if [[ $? -eq 0 && -n "$out" ]]; then
    __envee_deps=()
    eval "$out"
    __envee_pwd="$PWD"
    __envee_ok=1
    : > "$__envee_stamp"
  else
    __envee_ok=
  fi
}

_envee_chpwd() {
  # Preserve the caller's exit status: this runs from the prompt, and a shell
  # prompt that displays $? must not be told about envee's internals.
  local __envee_last=$?
  if [[ -n "$__envee_ok" && "$PWD" == "$__envee_pwd" ]]; then
    local f
    for f in "${__envee_deps[@]}"; do
      if [[ "$f" -nt "$__envee_stamp" ]]; then
        _envee_apply
        return $__envee_last
      fi
    done
    return $__envee_last
  fi
  _envee_apply
  return $__envee_last
}

_envee_precmd() {
  # Trigger on every prompt (for external edits); the guard above makes that
  # cheap when nothing has changed.
  _envee_chpwd
}

autoload -U add-zsh-hook
add-zsh-hook chpwd _envee_chpwd
add-zsh-hook precmd _envee_precmd
`
	return renderInitTemplate(tpl, selfPath)
}

// Export implements Adapter.
func (ZshAdapter) Export(key, value string) string {
	return "export " + key + "=" + value + ";"
}

// Unset implements Adapter.
func (ZshAdapter) Unset(key string) string {
	return "unset " + key + " 2>/dev/null;"
}

// SetPath implements Adapter.
func (ZshAdapter) SetPath(dirs []string) string {
	if len(dirs) == 0 {
		return ""
	}
	escaped := make([]string, len(dirs))
	for i, d := range dirs {
		escaped[i] = BashEscape(d)
	}
	return "export PATH=" + strings.Join(escaped, ":") + ":\"$PATH\";"
}

// Escape implements Adapter.
func (ZshAdapter) Escape(s string) string {
	return BashEscape(s)
}

// ---- fish adapter ----------------------------------------------------------

// FishAdapter implements Adapter for fish.
type FishAdapter struct{}

// Name implements Adapter.
func (FishAdapter) Name() Name { return Fish }

// Init implements Adapter.
func (FishAdapter) Init(selfPath string) string {
	return renderInitTemplate(`# envee shell hook for fish
#
# The hook fires on every prompt, so the common case -- nothing changed --
# must cost nothing. It compares the recorded dependency list against a stamp
# file using only fish builtins; invoking envee costs about 4 ms.
#
# 'string collect' below is load-bearing: command substitution in fish splits
# output into a LIST on newlines, and eval joins a list with spaces, so
# without it the generated statements arrive as one line and every variable
# after the first lands in the first one's value.
set -g __envee_stamp (test -n "$TMPDIR"; and echo $TMPDIR; or echo /tmp)/envee-stamp.(echo %self)
set -g __envee_deps

function _envee_apply
  set -l out ("{{.SelfPath}}" --quiet eval fish 2>/dev/null | string collect)
  if test $status -eq 0 -a -n "$out"
    set -g __envee_deps
    eval $out
    set -g __envee_pwd $PWD
    set -g __envee_ok 1
    # Truncate rather than touch: no external process.
    echo -n "" > $__envee_stamp
  else
    # Do not arm the fast path on failure, or 'envee trust' would not take
    # effect until the next directory change.
    set -e __envee_ok
  end
end

function _envee_hook --on-variable PWD
  # Preserve the caller's exit status: this runs from the prompt, and a prompt
  # that displays $status must not be told about envee's internals.
  set -l __envee_last $status
  if set -q __envee_ok; and test "$PWD" = "$__envee_pwd"
    for f in $__envee_deps
      if test "$f" -nt "$__envee_stamp"
        _envee_apply
        return $__envee_last
      end
    end
    return $__envee_last
  end
  _envee_apply
  return $__envee_last
end

function _envee_prompt --on-event fish_prompt
  _envee_hook
end
`, selfPath)
}

// Export implements Adapter.
func (FishAdapter) Export(key, value string) string {
	return "set -gx " + key + " " + value
}

// Unset implements Adapter.
func (FishAdapter) Unset(key string) string {
	return "set -e " + key
}

// SetPath implements Adapter.
func (FishAdapter) SetPath(dirs []string) string {
	if len(dirs) == 0 {
		return ""
	}
	escaped := make([]string, len(dirs))
	for i, d := range dirs {
		escaped[i] = FishEscape(d)
	}
	return "set -gx PATH " + strings.Join(escaped, " ") + " $PATH"
}

// Escape implements Adapter.
func (FishAdapter) Escape(s string) string {
	return FishEscape(s)
}

// FishEscape escapes a string for use as a fish argument.
func FishEscape(s string) string {
	if s == "" {
		return "''"
	}
	// Inside fish single quotes only \' and \\ are recognised as escapes.
	// The backslash must be doubled FIRST, otherwise a value ending in a
	// backslash escapes the closing quote and the rest of the line is
	// interpreted as code.
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, "'", `\'`)
	return "'" + s + "'"
}

// ---- nu (nushell) adapter --------------------------------------------------

// NuAdapter implements Adapter for nushell.
type NuAdapter struct{}

// Name implements Adapter.
func (NuAdapter) Name() Name { return Nu }

// Init implements Adapter.
//
// Nushell has no `eval`, so it cannot execute a block of generated statements
// in the caller's scope the way bash and zsh do. Two mechanisms make this
// work instead, both verified against nushell 0.115:
//
//   - `def --env` marks a command as able to mutate its caller's environment.
//     Both load-env and hide-env propagate out of one.
//   - An env_change hook given as a STRING is parsed and evaluated in the
//     caller's scope. A closure is not: env changes made inside one, including
//     via a `def --env` command called from it, stop at the closure boundary.
//
// So the hook body is a `def --env` command, and the registration is the
// string form that calls it. `envee eval nu` emits JSON rather than nushell
// statements, because a record is what load-env consumes.
func (NuAdapter) Init(selfPath string) string {
	return renderInitTemplate(`# envee shell hook for nushell
#
# _envee_hook must be `+"`def --env`"+`: that is what lets load-env and hide-env
# inside it affect your session. The hook below is registered as a string, not
# a closure, for the same reason -- a closure would swallow the changes.
def --env _envee_hook [] {
  let r = (^"{{.SelfPath}}" --quiet eval nu | complete)
  if $r.exit_code != 0 { return }
  if ($r.stdout | str trim | is-empty) { return }
  let d = ($r.stdout | from json)
  for k in $d.unset { hide-env --ignore-errors $k }
  $d.set | load-env
}

$env.config = ($env.config | upsert hooks.env_change.PWD [ "_envee_hook" ])
`, selfPath)
}

// Export implements Adapter.
func (NuAdapter) Export(key, value string) string {
	return fmt.Sprintf("$env.%s = %s", key, value)
}

// Unset implements Adapter.
func (NuAdapter) Unset(key string) string {
	return fmt.Sprintf("hide-env %s", key)
}

// SetPath implements Adapter.
func (NuAdapter) SetPath(dirs []string) string {
	if len(dirs) == 0 {
		return ""
	}
	escaped := make([]string, len(dirs))
	for i, d := range dirs {
		escaped[i] = NuEscape(d)
	}
	return "$env.PATH = [" + strings.Join(escaped, " ") + " ...$env.PATH]"
}

// Escape implements Adapter.
func (NuAdapter) Escape(s string) string {
	return NuEscape(s)
}

// NuEscape escapes a string for nushell.
func NuEscape(s string) string {
	if s == "" {
		return `""`
	}
	// Use double-quoted form with $'...' escape for control chars.
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '$':
			b.WriteString(`\$`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// DiffRenderer is an optional Adapter capability for shells that cannot
// evaluate a sequence of generated statements in the caller's scope.
//
// An adapter implementing it takes over rendering of the whole env diff, and
// Export/Unset/SetPath are not used for that shell.
type DiffRenderer interface {
	// RenderDiff returns the payload the shell hook consumes. set holds the
	// variables to define (including PATH when it changed), unset the ones to
	// remove.
	RenderDiff(set map[string]string, unset []string) string
}

// nuPayload is the JSON `envee eval nu` produces.
type nuPayload struct {
	Set   map[string]string `json:"set"`
	Unset []string          `json:"unset"`
}

// RenderDiff implements DiffRenderer.
//
// Nushell has no eval, so it gets a JSON record the hook feeds to load-env and
// hide-env instead of a script it cannot run.
func (NuAdapter) RenderDiff(set map[string]string, unset []string) string {
	if set == nil {
		set = map[string]string{}
	}
	if unset == nil {
		unset = []string{}
	}
	sort.Strings(unset)
	out, err := json.Marshal(nuPayload{Set: set, Unset: unset})
	if err != nil {
		// The input is a plain map of strings; marshalling it cannot fail.
		return ""
	}
	return string(out) + "\n"
}

// FastPathRenderer is an optional Adapter capability: emitting the state a
// shell hook needs to decide it can skip invoking envee entirely.
//
// The hook compares the recorded dependency list against a stamp file using
// the shell's own builtins, which costs nothing measurable (see the timings in
// the fast-path tests). Adapters that do not implement this keep the previous
// behaviour of invoking envee on every prompt.
type FastPathRenderer interface {
	// RenderFastPath emits shell code recording which files the resolved
	// environment depends on. deps are absolute paths.
	RenderFastPath(deps []string) string
}

// depsVar is the shell variable the generated hooks read.
const depsVar = "__envee_deps"

// RenderFastPath implements FastPathRenderer.
func (BashAdapter) RenderFastPath(deps []string) string {
	return posixDepsAssignment(deps)
}

// RenderFastPath implements FastPathRenderer.
func (ZshAdapter) RenderFastPath(deps []string) string {
	return posixDepsAssignment(deps)
}

// posixDepsAssignment renders a bash/zsh array assignment.
//
// Every path goes through the same escaping as a variable value: these are
// filesystem paths, which routinely contain spaces and can contain quotes and
// newlines, and they are about to be evaluated as shell code.
func posixDepsAssignment(deps []string) string {
	escaped := make([]string, len(deps))
	for i, d := range deps {
		escaped[i] = BashEscape(d)
	}
	return depsVar + "=(" + strings.Join(escaped, " ") + ");\n"
}

// RenderFastPath implements FastPathRenderer.
func (FishAdapter) RenderFastPath(deps []string) string {
	if len(deps) == 0 {
		return "set -g " + depsVar + "\n"
	}
	escaped := make([]string, len(deps))
	for i, d := range deps {
		escaped[i] = FishEscape(d)
	}
	return "set -g " + depsVar + " " + strings.Join(escaped, " ") + "\n"
}

// ---- pwsh (PowerShell) adapter ---------------------------------------------

// PwshAdapter implements Adapter for PowerShell.
type PwshAdapter struct{}

// Name implements Adapter.
func (PwshAdapter) Name() Name { return Pwsh }

// Init implements Adapter.
//
// The hook wraps the prompt function rather than registering an OnIdle engine
// event. Verified against PowerShell 7.6: an OnIdle -Action scriptblock runs
// in its own runspace and its $env: assignments never reach the session, while
// a prompt-function wrapper runs in the session and they do.
func (PwshAdapter) Init(selfPath string) string {
	return renderInitTemplate(`# envee shell hook for PowerShell
#
# Wrapping prompt is deliberate. Register-EngineEvent -SourceIdentifier
# PowerShell.OnIdle runs its -Action in a separate runspace, so the $env:
# assignments made there never reach your session.
function global:_envee_hook {
  $out = & "{{.SelfPath}}" --quiet eval pwsh 2>$null
  if ($LASTEXITCODE -eq 0 -and $out) {
    Invoke-Expression ($out -join "`+"`"+`n")
  }
}

if (-not (Test-Path variable:global:_envee_original_prompt)) {
  $global:_envee_original_prompt = $function:prompt
  function global:prompt {
    _envee_hook
    & $global:_envee_original_prompt
  }
}
`, selfPath)
}

// Export implements Adapter.
func (PwshAdapter) Export(key, value string) string {
	return fmt.Sprintf("$env:%s = %s", key, value)
}

// Unset implements Adapter.
func (PwshAdapter) Unset(key string) string {
	return fmt.Sprintf("Remove-Item Env:%s -ErrorAction SilentlyContinue", key)
}

// SetPath implements Adapter.
func (PwshAdapter) SetPath(dirs []string) string {
	if len(dirs) == 0 {
		return ""
	}
	// PwshEscape returns a single-quoted PowerShell literal. Concatenate
	// those literals with the separator rather than nesting them inside a
	// double-quoted string, which would put the quote characters themselves
	// into PATH.
	escaped := make([]string, len(dirs))
	for i, d := range dirs {
		escaped[i] = PwshEscape(d)
	}
	return "$env:PATH = " + strings.Join(escaped, " + ';' + ") + " + ';' + $env:PATH"
}

// Escape implements Adapter.
func (PwshAdapter) Escape(s string) string {
	return PwshEscape(s)
}

// PwshEscape escapes a string for PowerShell single-quoted form.
func PwshEscape(s string) string {
	if s == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}
