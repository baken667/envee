package shell

import (
	"strings"
	"testing"
)

func TestBashEscapeBasic(t *testing.T) {
	tests := []struct {
		in, want string
	}{
		{"", "''"},
		{"hello", "hello"},
		{"hello world", "'hello world'"},
		{"it's", `'it'\''s'`},
		{"$VAR", "'$VAR'"},
		{`"quoted"`, `'"quoted"'`},
		{"`backtick`", "'`backtick`'"},
		{"plain/path/to/file.txt", "plain/path/to/file.txt"},
		{"http://example.com:8080", "http://example.com:8080"},
	}
	for _, tt := range tests {
		got := BashEscape(tt.in)
		if got != tt.want {
			t.Errorf("BashEscape(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestBashEscapeControl(t *testing.T) {
	in := "line1\nline2"
	got := BashEscape(in)
	if !strings.Contains(got, `\n`) {
		t.Errorf("BashEscape should escape newlines, got %q", got)
	}
}

func TestSingleQuote(t *testing.T) {
	tests := []struct {
		in, want string
	}{
		{"", "''"},
		{"hello", "'hello'"},
		{"it's", `'it'\''s'`},
	}
	for _, tt := range tests {
		got := SingleQuote(tt.in)
		if got != tt.want {
			t.Errorf("SingleQuote(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestDetectShell(t *testing.T) {
	cases := map[string]Name{
		"bash":   Bash,
		"zsh":    Zsh,
		"fish":   Fish,
		"nu":     Nu,
		"nushell": Nu,
		"pwsh":   Pwsh,
		"powershell": Pwsh,
		"BASH":   Bash,
		"Zsh":    Zsh,
		"":       "",
	}
	for in, want := range cases {
		got := Detect(in)
		if got == nil {
			if want != "" {
				t.Errorf("Detect(%q) = nil, want %q", in, want)
			}
			continue
		}
		if got.Name() != want {
			t.Errorf("Detect(%q).Name() = %q, want %q", in, got.Name(), want)
		}
	}
}

func TestInitBashHasHook(t *testing.T) {
	a := BashAdapter{}
	out := a.Init("/usr/local/bin/envee")
	if !strings.Contains(out, "_envee_hook") {
		t.Error("bash init missing _envee_hook")
	}
	if !strings.Contains(out, "PROMPT_COMMAND") {
		t.Error("bash init missing PROMPT_COMMAND")
	}
	if !strings.Contains(out, "/usr/local/bin/envee") {
		t.Error("bash init missing self path")
	}
}

func TestInitZshHasHook(t *testing.T) {
	a := ZshAdapter{}
	out := a.Init("/usr/local/bin/envee")
	if !strings.Contains(out, "add-zsh-hook") {
		t.Error("zsh init missing add-zsh-hook")
	}
}

func TestInitFishHasHook(t *testing.T) {
	a := FishAdapter{}
	out := a.Init("/usr/local/bin/envee")
	if !strings.Contains(out, "function _envee_hook") {
		t.Error("fish init missing hook function")
	}
}

func TestBashExport(t *testing.T) {
	a := BashAdapter{}
	got := a.Export("FOO", "'bar'")
	if got != "export FOO='bar';" {
		t.Errorf("Export = %q", got)
	}
}

func TestBashUnset(t *testing.T) {
	a := BashAdapter{}
	got := a.Unset("FOO")
	if !strings.Contains(got, "unset FOO") {
		t.Errorf("Unset = %q", got)
	}
}

func TestSetPathBash(t *testing.T) {
	a := BashAdapter{}
	got := a.SetPath([]string{"/a", "/b"})
	if !strings.Contains(got, "PATH") {
		t.Error("SetPath should reference PATH")
	}
	if !strings.Contains(got, "/a") {
		t.Error("SetPath should include /a")
	}
	if !strings.Contains(got, "/b") {
		t.Error("SetPath should include /b")
	}
}
