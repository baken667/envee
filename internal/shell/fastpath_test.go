package shell

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// countingEnvee writes a stand-in for the envee binary that appends a line to
// a counter file on every invocation and prints the given eval output.
//
// Counting invocations is the whole point: the fast path is a claim about
// envee NOT being run, and only a counter can check that.
func countingEnvee(t *testing.T, counter, evalOutput string) string {
	t.Helper()
	skipOnWindows(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "envee")
	script := "#!/bin/sh\necho x >> " + counter + "\ncat <<'ENVEE_EOF'\n" + evalOutput + "ENVEE_EOF\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func readCount(t *testing.T, counter string) int {
	t.Helper()
	data, err := os.ReadFile(counter)
	if os.IsNotExist(err) {
		return 0
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Count(string(data), "\n")
}

// skipOnWindows guards the whole file: these hooks are POSIX shell scripts,
// and Windows paths cannot be interpolated into one — the backslashes are
// eaten as escapes, which is how this first showed up in CI.
func skipOnWindows(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("POSIX shell hooks; Windows uses the pwsh hook, covered separately")
	}
}

// shq single-quotes a path for interpolation into a shell script. Temporary
// directories are tame, but building shell scripts by concatenation is exactly
// the habit that produced the escaping bugs this project has already had.
func shq(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

type fastPathCase struct {
	shell  string
	init   func(string) string
	deps   func([]string) string
	entry  string
	export string
}

func fastPathCases() []fastPathCase {
	return []fastPathCase{
		{"bash", func(p string) string { return BashAdapter{}.Init(p) },
			BashAdapter{}.RenderFastPath, "_envee_hook", "export MARK=one;\n"},
		{"zsh", func(p string) string { return ZshAdapter{}.Init(p) },
			ZshAdapter{}.RenderFastPath, "_envee_chpwd", "export MARK=one;\n"},
		{"fish", func(p string) string { return FishAdapter{}.Init(p) },
			FishAdapter{}.RenderFastPath, "_envee_hook", "set -gx MARK one\n"},
	}
}

// runScript executes a script in the given shell and returns its output.
func runScript(t *testing.T, shellName, script string) string {
	t.Helper()
	bin, err := exec.LookPath(shellName)
	if err != nil {
		t.Skipf("%s not installed", shellName)
	}
	out, err := exec.Command(bin, "-c", script).CombinedOutput()
	if err != nil {
		t.Fatalf("%s failed: %v\n%s", shellName, err, out)
	}
	return string(out)
}

// The point of the whole exercise: with nothing changed, repeated prompts must
// not run envee even once more.
func TestFastPathSkipsRepeatedPrompts(t *testing.T) {
	for _, tc := range fastPathCases() {
		t.Run(tc.shell, func(t *testing.T) {
			dir := t.TempDir()
			counter := filepath.Join(dir, "calls")
			watched := filepath.Join(dir, "envee.toml")
			if err := os.WriteFile(watched, []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			bin := countingEnvee(t, counter, tc.export+tc.deps([]string{watched}))

			hook := filepath.Join(dir, "hook")
			if err := os.WriteFile(hook, []byte(tc.init(bin)), 0o644); err != nil {
				t.Fatal(err)
			}

			// One initial invocation, then nine more prompts with nothing changed.
			script := "cd " + shq(dir) + "\nsource " + shq(hook) + "\n" + tc.entry + "\n" +
				strings.Repeat(tc.entry+"\n", 9)
			runScript(t, tc.shell, script)

			if got := readCount(t, counter); got != 1 {
				t.Errorf("envee ran %d times across 10 prompts; the fast path should have "+
					"allowed exactly 1", got)
			}
		})
	}
}

// A dependency changing must break the fast path.
func TestFastPathReactsToChangedDependency(t *testing.T) {
	for _, tc := range fastPathCases() {
		t.Run(tc.shell, func(t *testing.T) {
			dir := t.TempDir()
			counter := filepath.Join(dir, "calls")
			watched := filepath.Join(dir, "envee.toml")
			if err := os.WriteFile(watched, []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			bin := countingEnvee(t, counter, tc.export+tc.deps([]string{watched}))

			hook := filepath.Join(dir, "hook")
			if err := os.WriteFile(hook, []byte(tc.init(bin)), 0o644); err != nil {
				t.Fatal(err)
			}

			// Prompt, touch the dependency, prompt again. sleep gives the
			// filesystem a distinguishable mtime.
			script := "cd " + shq(dir) + "\nsource " + shq(hook) + "\n" + tc.entry + "\n" +
				tc.entry + "\nsleep 1.1\ntouch " + shq(watched) + "\n" + tc.entry + "\n"
			runScript(t, tc.shell, script)

			if got := readCount(t, counter); got != 2 {
				t.Errorf("envee ran %d times; expected 2 (once initially, once after the "+
					"dependency changed)", got)
			}
		})
	}
}

// Changing directory must break the fast path even when no file changed.
func TestFastPathReactsToDirectoryChange(t *testing.T) {
	for _, tc := range fastPathCases() {
		t.Run(tc.shell, func(t *testing.T) {
			dir := t.TempDir()
			other := filepath.Join(dir, "sub")
			if err := os.MkdirAll(other, 0o755); err != nil {
				t.Fatal(err)
			}
			counter := filepath.Join(dir, "calls")
			watched := filepath.Join(dir, "envee.toml")
			if err := os.WriteFile(watched, []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			bin := countingEnvee(t, counter, tc.export+tc.deps([]string{watched}))

			hook := filepath.Join(dir, "hook")
			if err := os.WriteFile(hook, []byte(tc.init(bin)), 0o644); err != nil {
				t.Fatal(err)
			}

			script := "cd " + shq(dir) + "\nsource " + shq(hook) + "\n" + tc.entry + "\n" +
				"cd " + shq(other) + "\n" + tc.entry + "\n"
			runScript(t, tc.shell, script)

			if got := readCount(t, counter); got != 2 {
				t.Errorf("envee ran %d times; expected 2 (the directory changed)", got)
			}
		})
	}
}

// A failing envee must NOT arm the fast path, or `envee trust` would appear to
// do nothing until the next directory change.
func TestFastPathNotArmedOnFailure(t *testing.T) {
	for _, tc := range fastPathCases() {
		t.Run(tc.shell, func(t *testing.T) {
			skipOnWindows(t)
			dir := t.TempDir()
			counter := filepath.Join(dir, "calls")

			// A stand-in that counts and then fails, as an untrusted config does.
			failing := filepath.Join(dir, "envee")
			script := "#!/bin/sh\necho x >> " + counter + "\nexit 3\n"
			if err := os.WriteFile(failing, []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}

			hook := filepath.Join(dir, "hook")
			if err := os.WriteFile(hook, []byte(tc.init(failing)), 0o644); err != nil {
				t.Fatal(err)
			}

			body := "cd " + shq(dir) + "\nsource " + shq(hook) + "\n" + strings.Repeat(tc.entry+"\n", 3)
			runScript(t, tc.shell, body)

			if got := readCount(t, counter); got != 3 {
				t.Errorf("envee ran %d times; a failing run must keep retrying, so 3 prompts "+
					"means 3 attempts", got)
			}
		})
	}
}

// Paths with spaces and quotes must survive: this list is evaluated as shell
// code, exactly like variable values.
func TestFastPathHandlesAwkwardPaths(t *testing.T) {
	for _, tc := range fastPathCases() {
		t.Run(tc.shell, func(t *testing.T) {
			dir := t.TempDir()
			awkward := filepath.Join(dir, "a dir with spaces")
			if err := os.MkdirAll(awkward, 0o755); err != nil {
				t.Fatal(err)
			}
			dep := filepath.Join(awkward, "it's here.toml")
			if err := os.WriteFile(dep, []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}

			counter := filepath.Join(dir, "calls")
			bin := countingEnvee(t, counter, tc.export+tc.deps([]string{dep}))
			hook := filepath.Join(dir, "hook")
			if err := os.WriteFile(hook, []byte(tc.init(bin)), 0o644); err != nil {
				t.Fatal(err)
			}

			body := "cd " + shq(dir) + "\nsource " + shq(hook) + "\n" + strings.Repeat(tc.entry+"\n", 4)
			out := runScript(t, tc.shell, body)

			if got := readCount(t, counter); got != 1 {
				t.Errorf("envee ran %d times, want 1 — the awkward path likely broke the "+
					"dependency list\noutput: %s", got, out)
			}
		})
	}
}

// The rendered list must be shell-escaped, not concatenated raw.
func TestRenderFastPathEscapes(t *testing.T) {
	awkward := []string{"/a dir/it's here.toml", "/plain/path.toml"}

	bash := BashAdapter{}.RenderFastPath(awkward)
	if !strings.Contains(bash, `'/a dir/it'\''s here.toml'`) {
		t.Errorf("bash: quote not escaped: %s", bash)
	}
	fish := FishAdapter{}.RenderFastPath(awkward)
	if !strings.Contains(fish, `\'`) {
		t.Errorf("fish: quote not escaped: %s", fish)
	}
	// Composite literal in an if-header needs its own statement in Go.
	empty := BashAdapter{}.RenderFastPath(nil)
	if !strings.Contains(empty, "=()") {
		t.Errorf("an empty list must still reset the variable: %q", empty)
	}
}

// The hook runs from the prompt, so it must leave the caller's exit status
// alone. A prompt that displays $? would otherwise report envee's internals
// instead of the command the user just ran.
//
// This surfaced as a test failure: the fish hook propagated the stand-in's
// exit 3 outward.
func TestHookPreservesExitStatus(t *testing.T) {
	cases := []struct {
		shell     string
		init      func(string) string
		deps      func([]string) string
		entry     string
		export    string
		setStatus string
		probe     string
	}{
		// (exit N) is a subshell in POSIX shells but a command substitution in
		// fish, which has no equivalent — hence the per-shell spelling.
		{"bash", func(p string) string { return BashAdapter{}.Init(p) },
			BashAdapter{}.RenderFastPath, "_envee_hook", "export MARK=one;\n",
			"(exit 42)", `echo "status=$?"`},
		{"zsh", func(p string) string { return ZshAdapter{}.Init(p) },
			ZshAdapter{}.RenderFastPath, "_envee_chpwd", "export MARK=one;\n",
			"(exit 42)", `echo "status=$?"`},
		{"fish", func(p string) string { return FishAdapter{}.Init(p) },
			FishAdapter{}.RenderFastPath, "_envee_hook", "set -gx MARK one\n",
			"sh -c 'exit 42'", `echo "status=$status"`},
	}

	for _, tc := range cases {
		for _, mode := range []string{"succeeding", "failing"} {
			t.Run(tc.shell+"/"+mode, func(t *testing.T) {
				skipOnWindows(t)
				dir := t.TempDir()
				counter := filepath.Join(dir, "calls")
				dep := filepath.Join(dir, "envee.toml")
				if err := os.WriteFile(dep, []byte("x"), 0o644); err != nil {
					t.Fatal(err)
				}

				var bin string
				if mode == "succeeding" {
					bin = countingEnvee(t, counter, tc.export+tc.deps([]string{dep}))
				} else {
					bin = filepath.Join(dir, "envee")
					body := "#!/bin/sh\necho x >> " + counter + "\nexit 3\n"
					if err := os.WriteFile(bin, []byte(body), 0o755); err != nil {
						t.Fatal(err)
					}
				}

				hook := filepath.Join(dir, "hook")
				if err := os.WriteFile(hook, []byte(tc.init(bin)), 0o644); err != nil {
					t.Fatal(err)
				}

				// Produce a known exit status, then run the hook, then report $?.
				script := "cd " + shq(dir) + "\nsource " + shq(hook) + "\n" +
					tc.setStatus + "\n" + tc.entry + "\n" + tc.probe + "\n"

				shellBin, err := exec.LookPath(tc.shell)
				if err != nil {
					t.Skipf("%s not installed", tc.shell)
				}
				out, _ := exec.Command(shellBin, "-c", script).CombinedOutput()

				if !strings.Contains(string(out), "status=42") {
					t.Errorf("the hook clobbered the caller's exit status\n  want status=42\n  got:  %s",
						strings.TrimSpace(string(out)))
				}
			})
		}
	}
}
