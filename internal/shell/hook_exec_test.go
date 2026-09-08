package shell

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// fakeEnvee writes an executable that stands in for the envee binary and
// prints the given eval output, so the hook's own plumbing can be exercised
// without building the CLI.
func fakeEnvee(t *testing.T, evalOutput string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("POSIX shells only")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "envee")
	script := "#!/bin/sh\ncat <<'ENVEE_EOF'\n" + evalOutput + "ENVEE_EOF\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// runHook sources a generated hook in a real shell, invokes it, and prints the
// resulting variables back out.
//
// This deliberately exercises the hook AS WRITTEN rather than a hand-rolled
// equivalent. An earlier test fed the eval output to the shell through an
// environment variable, which made it a single string -- so it passed while
// the fish hook was broken, because fish's command substitution splits output
// into a LIST and eval then joins it with spaces.
func runHook(t *testing.T, shellName, hook, entry, probe string) string {
	t.Helper()
	bin, err := exec.LookPath(shellName)
	if err != nil {
		t.Skipf("%s not installed", shellName)
	}
	dir := t.TempDir()
	hookPath := filepath.Join(dir, "hook."+shellName)
	if writeErr := os.WriteFile(hookPath, []byte(hook), 0o644); writeErr != nil {
		t.Fatal(writeErr)
	}

	script := "source " + hookPath + "\n" + entry + "\n" + probe + "\n"
	out, err := exec.Command(bin, "-c", script).CombinedOutput()
	if err != nil {
		t.Fatalf("%s failed running the hook: %v\n%s", shellName, err, out)
	}
	return string(out)
}

const hookEvalOutputPOSIX = `export ALPHA=one;
export BETA=two;
export GAMMA='has spaces';
`

const hookEvalOutputFish = `set -gx ALPHA one
set -gx BETA two
set -gx GAMMA 'has spaces'
`

// Every variable the hook receives must be set, not just the first. This is
// the exact failure the fish hook shipped with: without `string collect` the
// statements arrived as one line and everything after the first landed inside
// the first variable's value.
func TestHookAppliesEveryVariable(t *testing.T) {
	// The entry point differs per adapter: bash and fish define _envee_hook,
	// zsh registers _envee_chpwd via add-zsh-hook.
	cases := []struct {
		shell  string
		hook   func(string) string
		output string
		entry  string
		probe  string
	}{
		{"bash", func(p string) string { return BashAdapter{}.Init(p) }, hookEvalOutputPOSIX, "_envee_hook",
			`printf 'A=[%s] B=[%s] G=[%s]\n' "$ALPHA" "$BETA" "$GAMMA"`},
		{"zsh", func(p string) string { return ZshAdapter{}.Init(p) }, hookEvalOutputPOSIX, "_envee_chpwd",
			`printf 'A=[%s] B=[%s] G=[%s]\n' "$ALPHA" "$BETA" "$GAMMA"`},
		{"fish", func(p string) string { return FishAdapter{}.Init(p) }, hookEvalOutputFish, "_envee_hook",
			`printf 'A=[%s] B=[%s] G=[%s]\n' "$ALPHA" "$BETA" "$GAMMA"`},
	}

	for _, tc := range cases {
		t.Run(tc.shell, func(t *testing.T) {
			got := runHook(t, tc.shell, tc.hook(fakeEnvee(t, tc.output)), tc.entry, tc.probe)
			want := "A=[one] B=[two] G=[has spaces]"
			if !strings.Contains(got, want) {
				t.Errorf("hook did not apply every variable\n  want: %s\n  got:  %s", want, strings.TrimSpace(got))
			}
		})
	}
}

// fish specifically: assert the mechanism, so removing `string collect` fails
// here with an explanation rather than as a puzzling value mismatch.
func TestFishHookCollectsOutput(t *testing.T) {
	hook := FishAdapter{}.Init("/usr/local/bin/envee")
	if !strings.Contains(hook, "string collect") {
		t.Error("the fish hook must pipe through `string collect`: command substitution " +
			"splits output into a list, and eval joins a list with spaces, so the " +
			"statements would arrive as a single line")
	}
}
