package template

import (
	"strings"
	"testing"
)

func TestRenderLiteral(t *testing.T) {
	e := New()
	got, err := e.Render("hello world", &Context{})
	if err != nil {
		t.Fatal(err)
	}
	if got != "hello world" {
		t.Errorf("got %q, want %q", got, "hello world")
	}
}

func TestRenderVariable(t *testing.T) {
	e := New()
	ctx := &Context{
		ConfigRoot: "/home/user/proj",
		Profile:    "dev",
		Env:        map[string]string{"MY_VAR": "value"},
		OSEnv:      map[string]string{},
	}
	tests := []struct {
		tpl, want string
	}{
		{"{{config_root}}", "/home/user/proj"},
		{"{{profile}}", "dev"},
		{"{{env.MY_VAR}}", "value"},
		{"prefix-{{config_root}}-suffix", "prefix-/home/user/proj-suffix"},
		{"{{config_root}}/logs/{{profile}}.log", "/home/user/proj/logs/dev.log"},
	}
	for _, tt := range tests {
		got, err := e.Render(tt.tpl, ctx)
		if err != nil {
			t.Errorf("Render(%q) error: %v", tt.tpl, err)
			continue
		}
		if got != tt.want {
			t.Errorf("Render(%q) = %q, want %q", tt.tpl, got, tt.want)
		}
	}
}

func TestRenderFilters(t *testing.T) {
	e := New()
	ctx := &Context{
		ConfigRoot: "/home/user",
		Profile:    "dev",
		Env:        map[string]string{"UNSET_VAR": ""},
		OSEnv:      map[string]string{},
	}
	tests := []struct {
		tpl, want string
	}{
		{"{{profile | upper}}", "DEV"},
		{"{{profile | lower}}", "dev"},
		{"{{config_root | upper}}", "/HOME/USER"},
		{"{{env.UNSET_VAR | default('fallback')}}", "fallback"},
		{"{{env.SET_VAR | default('fb')}}", "fb"},
	}
	for _, tt := range tests {
		got, err := e.Render(tt.tpl, ctx)
		if err != nil {
			t.Errorf("Render(%q) error: %v", tt.tpl, err)
			continue
		}
		if got != tt.want {
			t.Errorf("Render(%q) = %q, want %q", tt.tpl, got, tt.want)
		}
	}
}

func TestRenderError(t *testing.T) {
	e := New()
	ctx := &Context{Env: map[string]string{}, OSEnv: map[string]string{}}
	_, err := e.Render("{{ undefined }}", ctx)
	if err == nil {
		t.Error("expected error for unknown variable")
	}
}

func TestRenderUnterminated(t *testing.T) {
	e := New()
	_, err := e.Render("unterminated {{ var", &Context{Env: map[string]string{}, OSEnv: map[string]string{}})
	if err == nil {
		t.Error("expected error for unterminated template")
	}
}

func TestQuoteFilter(t *testing.T) {
	e := New()
	got, err := e.Render(`{{config_root | quote}}`, &Context{ConfigRoot: "/a b"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(got, "'") || !strings.HasSuffix(got, "'") {
		t.Errorf("quote should wrap in single quotes, got %q", got)
	}
}

func TestDirnameBasename(t *testing.T) {
	e := New()
	got, err := e.Render("{{config_root | dirname}}", &Context{ConfigRoot: "/a/b/c"})
	if err != nil {
		t.Fatal(err)
	}
	if got != "/a/b" {
		t.Errorf("dirname = %q, want /a/b", got)
	}
	got, _ = e.Render("{{config_root | basename}}", &Context{ConfigRoot: "/a/b/c"})
	if got != "c" {
		t.Errorf("basename = %q, want c", got)
	}
}
