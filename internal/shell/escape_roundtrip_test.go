package shell

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// evilValues are environment-variable values that a hostile (or merely
// awkward) .env file or secret plugin can produce. Every one of them must
// survive a round trip through `envee eval <shell>` byte for byte, and none
// of them may cause the shell to execute anything.
//
// NUL is excluded because it cannot travel through the process environment
// at all.
var evilValues = []struct {
	name  string
	value string
}{
	{"plain", "hello"},
	{"empty", ""},
	{"space", "a b"},
	{"single_quote", "it's"},
	{"double_quote", `say "hi"`},
	{"backslash", `back\slash`},
	{"trailing_backslash", `ends_with\`},
	{"double_backslash", `a\\b`},
	{"dollar", "$HOME and ${PATH}"},
	{"backtick", "`id`"},
	{"subshell", "$(id)"},
	{"semicolon", "a;b"},
	{"bang", "history!expansion"},
	{"newline", "line1\nline2"},
	{"crlf", "line1\r\nline2"},
	{"tab", "a\tb"},
	{"utf8", "Привет, мир"},
	{"emoji", "🎉 done"},
	{"utf8_with_quote", "don't — не надо"},
	{"glob", "*.go ?x [a-z]"},
	{"pipe_redirect", "a | b > c < d & e"},
	// The exact payload that used to escape $'...' quoting and hand the
	// remainder of the value to the shell as code.
	{"ansi_c_breakout", "a\nb'; echo INJECTED-COMMAND-RAN; '"},
	{"ansi_c_backslash_breakout", "a\nb\\"},
	{"quote_then_newline", "'\n'"},
	{"only_quotes", `'''`},
}

// runShellRoundTrip evaluates the generated export statement in a real shell
// and prints the resulting variable back out, exactly as the envee hook does.
func runShellRoundTrip(t *testing.T, shellBin string, script string, generated string) (string, bool) {
	t.Helper()
	bin, err := exec.LookPath(shellBin)
	if err != nil {
		t.Skipf("%s not available on this machine", shellBin)
		return "", false
	}
	cmd := exec.Command(bin, "-c", script)
	cmd.Env = append(os.Environ(), "ENVEE_TEST_OUT="+generated)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("%s failed on generated script %q: %v", shellBin, generated, err)
	}
	return string(out), true
}

func TestBashEscapeRoundTrip(t *testing.T) {
	const script = `eval "$ENVEE_TEST_OUT"; printf '%s' "$V"`
	for _, adapter := range []Adapter{BashAdapter{}, ZshAdapter{}} {
		for _, tc := range evilValues {
			t.Run(string(adapter.Name())+"/"+tc.name, func(t *testing.T) {
				generated := adapter.Export("V", adapter.Escape(tc.value))
				got, ok := runShellRoundTrip(t, string(adapter.Name()), script, generated)
				if !ok {
					return
				}
				if got != tc.value {
					t.Errorf("round trip corrupted value\n  generated: %s\n  want %q\n  got  %q",
						generated, tc.value, got)
				}
				if strings.Contains(got, "INJECTED-COMMAND-RAN") && !strings.Contains(tc.value, "INJECTED-COMMAND-RAN") {
					t.Errorf("command injection: %s", generated)
				}
			})
		}
	}
}

// TestBashEscapeNoCommandExecution is the direct regression for the escaping
// hole: the payload must be exported as data, never executed. If the shell
// runs it, the marker lands on stdout on its own line.
func TestBashEscapeNoCommandExecution(t *testing.T) {
	const payload = "a\nb'; echo INJECTED-COMMAND-RAN; '"
	const script = `eval "$ENVEE_TEST_OUT"; printf 'VALUE=[%s]' "$V"`

	adapter := BashAdapter{}
	generated := adapter.Export("V", adapter.Escape(payload))
	got, ok := runShellRoundTrip(t, "bash", script, generated)
	if !ok {
		return
	}
	want := "VALUE=[" + payload + "]"
	if got != want {
		t.Fatalf("payload was not treated as inert data\n  generated: %s\n  want %q\n  got  %q",
			generated, want, got)
	}
}

func TestFishEscapeRoundTrip(t *testing.T) {
	const script = `eval $ENVEE_TEST_OUT; printf '%s' "$V"`
	adapter := FishAdapter{}
	for _, tc := range evilValues {
		t.Run(tc.name, func(t *testing.T) {
			generated := adapter.Export("V", adapter.Escape(tc.value))
			got, ok := runShellRoundTrip(t, "fish", script, generated)
			if !ok {
				return
			}
			if got != tc.value {
				t.Errorf("round trip corrupted value\n  generated: %s\n  want %q\n  got  %q",
					generated, tc.value, got)
			}
		})
	}
}

// TestSetPathRoundTrip covers the PATH pipe, which uses the same escaping but
// a different assembly path in each adapter.
func TestSetPathRoundTrip(t *testing.T) {
	dirs := []string{"/usr/local/bin", "/opt/with space/bin", `/opt/with'quote/bin`}
	const script = `PATH=/usr/bin:/bin; eval "$ENVEE_TEST_OUT"; printf '%s' "$PATH"`

	adapter := BashAdapter{}
	generated := adapter.SetPath(dirs)
	got, ok := runShellRoundTrip(t, "bash", script, generated)
	if !ok {
		return
	}
	want := strings.Join(dirs, ":") + ":/usr/bin:/bin"
	if got != want {
		t.Errorf("PATH round trip failed\n  generated: %s\n  want %q\n  got  %q", generated, want, got)
	}
}

// TestSetPathEmpty guards against emitting an empty PATH element, which POSIX
// shells resolve as the current working directory.
func TestSetPathEmpty(t *testing.T) {
	for _, adapter := range []Adapter{BashAdapter{}, ZshAdapter{}, FishAdapter{}, NuAdapter{}, PwshAdapter{}} {
		if got := adapter.SetPath(nil); got != "" {
			t.Errorf("%s.SetPath(nil) = %q, want empty (an empty PATH entry means cwd)",
				adapter.Name(), got)
		}
	}
}
