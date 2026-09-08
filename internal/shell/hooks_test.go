package shell

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The shipped nushell hook was a syntax error: `{|` instead of a valid
// closure, five parse errors in total, so `envee init nu` produced something
// that could never be sourced. `nu --ide-check` reports diagnostics as JSON
// lines, which makes that checkable.
func TestNuInitParses(t *testing.T) {
	if _, err := exec.LookPath("nu"); err != nil {
		t.Skip("nushell not installed")
	}

	dir := t.TempDir()
	path := filepath.Join(dir, "hook.nu")
	if err := os.WriteFile(path, []byte(NuAdapter{}.Init("/usr/local/bin/envee")), 0o644); err != nil {
		t.Fatal(err)
	}

	out, err := exec.Command("nu", "--ide-check", "50", path).CombinedOutput()
	if err != nil {
		t.Fatalf("nu --ide-check failed to run: %v\n%s", err, out)
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.Contains(line, `"severity":"Error"`) {
			t.Errorf("generated nushell hook does not parse: %s", line)
		}
	}
}

// The nushell hook only works because _envee_hook is `def --env` — that is
// what lets load-env and hide-env inside it reach the caller. Without it the
// hook runs and silently changes nothing.
func TestNuInitUsesEnvAwareDef(t *testing.T) {
	got := NuAdapter{}.Init("/usr/local/bin/envee")
	if !strings.Contains(got, "def --env _envee_hook") {
		t.Error("_envee_hook must be `def --env`, or its env changes do not propagate")
	}
	// The registration must be the string form. A closure swallows env
	// changes, including those made by a `def --env` command called from it.
	if !strings.Contains(got, `hooks.env_change.PWD [ "_envee_hook" ]`) {
		t.Errorf("hook must be registered as a string, not a closure:\n%s", got)
	}
}

// PowerShell's OnIdle -Action runs in a separate runspace, so $env:
// assignments there never reach the session. The hook must wrap prompt.
func TestPwshInitDoesNotUseOnIdle(t *testing.T) {
	got := PwshAdapter{}.Init("/usr/local/bin/envee")
	// Check the code, not the comment that explains why OnIdle is avoided.
	if strings.Contains(stripPwshComments(got), "Register-EngineEvent") {
		t.Error("OnIdle runs in its own runspace; its $env: assignments do not reach the session")
	}
	if !strings.Contains(got, "function global:prompt") {
		t.Errorf("hook must wrap the prompt function:\n%s", got)
	}
}

func TestPwshInitParses(t *testing.T) {
	if _, err := exec.LookPath("pwsh"); err != nil {
		t.Skip("powershell not installed")
	}

	dir := t.TempDir()
	path := filepath.Join(dir, "hook.ps1")
	if err := os.WriteFile(path, []byte(PwshAdapter{}.Init("/usr/local/bin/envee")), 0o644); err != nil {
		t.Fatal(err)
	}

	// Parse without executing: a parse error becomes a non-zero exit.
	script := `$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile('` + path + `', [ref]$null, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) { $errors | ForEach-Object { $_.Message }; exit 1 }`
	out, err := exec.Command("pwsh", "-NoProfile", "-Command", script).CombinedOutput()
	if err != nil {
		t.Errorf("generated PowerShell hook does not parse:\n%s", out)
	}
}

// Nushell has no eval, so `envee eval nu` emits JSON for load-env rather than
// statements. NuAdapter must therefore be a DiffRenderer.
func TestNuRendersJSONDiff(t *testing.T) {
	var adapter Adapter = NuAdapter{}
	renderer, ok := adapter.(DiffRenderer)
	if !ok {
		t.Fatal("NuAdapter must implement DiffRenderer; nushell cannot evaluate generated statements")
	}

	got := renderer.RenderDiff(
		map[string]string{"PATH": "/a:/b", "DATABASE_URL": "postgres://x"},
		[]string{"OLD_VAR", "ANOTHER"},
	)

	var payload struct {
		Set   map[string]string `json:"set"`
		Unset []string          `json:"unset"`
	}
	if err := json.Unmarshal([]byte(got), &payload); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, got)
	}
	if payload.Set["PATH"] != "/a:/b" || payload.Set["DATABASE_URL"] != "postgres://x" {
		t.Errorf("set = %#v", payload.Set)
	}
	// Sorted, so the output is deterministic across runs.
	if len(payload.Unset) != 2 || payload.Unset[0] != "ANOTHER" || payload.Unset[1] != "OLD_VAR" {
		t.Errorf("unset = %#v, want it sorted", payload.Unset)
	}
}

// Empty collections must still marshal as [] and {}, not null: the hook does
// `for k in $d.unset` and `$d.set | load-env`, and null breaks both.
func TestNuRenderDiffEmptyCollections(t *testing.T) {
	got := NuAdapter{}.RenderDiff(nil, nil)
	if !strings.Contains(got, `"set":{}`) || !strings.Contains(got, `"unset":[]`) {
		t.Errorf("empty collections must not marshal as null: %s", got)
	}
}

// Values are carried as JSON, so the shell-quoting hazards do not apply --
// but they must still survive the round trip untouched.
func TestNuRenderDiffPreservesAwkwardValues(t *testing.T) {
	values := map[string]string{
		"QUOTES":    `he said "hi" and 'bye'`,
		"NEWLINE":   "line1\nline2",
		"BACKSLASH": `C:\path\to`,
		"UTF8":      "Привет 🎉",
		"DOLLAR":    "$HOME and `id`",
	}
	got := NuAdapter{}.RenderDiff(values, nil)

	var payload struct {
		Set map[string]string `json:"set"`
	}
	if err := json.Unmarshal([]byte(got), &payload); err != nil {
		t.Fatalf("not valid JSON: %v", err)
	}
	for k, want := range values {
		if payload.Set[k] != want {
			t.Errorf("%s = %q, want %q", k, payload.Set[k], want)
		}
	}
}

// stripPwshComments removes whole-line # comments so assertions about the
// generated code are not satisfied (or defeated) by prose.
func stripPwshComments(script string) string {
	var b strings.Builder
	for _, line := range strings.Split(script, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		b.WriteString(line)
		b.WriteString("\n")
	}
	return b.String()
}
