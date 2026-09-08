// Package shell provides shell-specific adapters for emitting env changes.
//
// Each supported shell (bash, zsh, fish, nu, pwsh, ...) implements the
// Adapter interface, which knows how to format an env diff as commands
// the shell can eval.
//
// See docs/adr/0005-shell-hooks.md.
package shell

import (
	"fmt"
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
# See https://github.com/baken667/envee#shell-integration for details.
_envee_hook() {
  local previous_exit_status=$?
  local out
  out="$("{{.SelfPath}}" --quiet eval bash 2>/dev/null)"
  local rc=$?
  if [[ $rc -eq 0 && -n "$out" ]]; then
    eval "$out"
  fi
  return $previous_exit_status
}

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
_envee_chpwd() {
  local out
  out="$("{{.SelfPath}}" --quiet eval zsh 2>/dev/null)"
  local rc=$?
  if [[ $rc -eq 0 && -n "$out" ]]; then
    eval "$out"
  fi
}

_envee_precmd() {
  # Trigger on every prompt (for external edits)
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
function _envee_hook --on-variable PWD
  set -l out ("{{.SelfPath}}" --quiet eval fish 2>/dev/null)
  if test $status -eq 0 -a -n "$out"
    eval $out
  end
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
func (NuAdapter) Init(selfPath string) string {
	return renderInitTemplate(`# envee shell hook for nushell
$env.ENVEE_HOOK = {|
  let out = (^"{{.SelfPath}}" --quiet eval nu | complete)
  if $out.exit_code == 0 and ($out.stdout | str length) > 0 {
    nu -c $out.stdout
  }
}
$env.config = ($env.config | upsert hooks.env_change.PWD {|| $env.ENVEE_HOOK })
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

// ---- pwsh (PowerShell) adapter ---------------------------------------------

// PwshAdapter implements Adapter for PowerShell.
type PwshAdapter struct{}

// Name implements Adapter.
func (PwshAdapter) Name() Name { return Pwsh }

// Init implements Adapter.
func (PwshAdapter) Init(selfPath string) string {
	return renderInitTemplate(`# envee shell hook for PowerShell
function _envee_hook {
  $previous = $?
  $out = & "{{.SelfPath}}" --quiet eval pwsh 2>$null
  if ($LASTEXITCODE -eq 0 -and $out) {
    Invoke-Expression $out
  }
}

# Trigger on prompt
if (-not (Get-Variable -Name _envee_registered -Scope Global -ErrorAction SilentlyContinue)) {
  $global:_envee_registered = $true
  Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action { _envee_hook } | Out-Null
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
