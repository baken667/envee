package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/baken667/envee/internal/directive"
	"github.com/baken667/envee/internal/resolver"
	"github.com/baken667/envee/internal/shell"
)

// runEvalForTest is a helper that runs the eval pipeline against a given
// config directory and returns the shell script that would be emitted.
//
// Mirrors what cli/eval.go does internally, but without cobra boilerplate
// so tests can be golden.
func runEvalForTest(t *testing.T, configDir, profile, shellName string) string {
	t.Helper()

	// Golden tests assert specific values for some {{env.X}} lookups
	// (e.g. GIT_SHA defaults to "local"). On CI the runner exports
	// GITHUB_SHA which would shadow our default, so we clear it for
	// the duration of the test.
	t.Setenv("GITHUB_SHA", "")
	t.Setenv("GIT_COMMIT", "")

	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	_ = cwd

	res, err := resolver.New(configDir)
	if err != nil {
		t.Fatal(err)
	}
	res.SetProfile(profile)

	cfg, err := res.LoadAll()
	if err != nil {
		t.Fatal(err)
	}

	activeProfile := profile
	if activeProfile == "" {
		activeProfile = cfg.Profile
	}

	osEnv := envToMap(os.Environ())
	result, err := directive.Apply(t.Context(), cfg, directive.ApplyOptions{
		ConfigRoot: filepath.Dir(cfg.Path),
		Profile:    activeProfile,
		Cwd:        configDir,
		OSEnv:      osEnv,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}

	adapter := shell.Detect(shellName)
	if adapter == nil {
		t.Fatalf("unsupported shell: %s", shellName)
	}

	return renderShellDiff(adapter, result, osEnv)
}

// TestGoldenBasic verifies key invariants for examples/basic.
//
// We use invariant checks rather than exact-string match because the
// "rest of $PATH" portion depends on the system environment.
func TestGoldenBasic(t *testing.T) {
	got := runEvalForTest(t, "../../examples/basic", "", "bash")
	got = normalizePath(got, resolveConfigDir(t, "../../examples/basic"), "/Users/.../examples/basic")

	mustContain := []string{
		"export SERVICE_NAME=myapp;",
		"export DATABASE_URL=postgres://localhost:5432/mydb;",
		"export PORT=5432;",
		"export DEBUG=true;",
		"export API_KEY=dev-key-not-for-prod;",
		"export DATABASE_POOL_SIZE=10;",
		"export LOG_FORMAT=json;",
		"export LOG_LEVEL=info;",
		"export LOG_PATH=/Users/.../examples/basic/logs/dev.log;",
		"export GIT_SHA=local;",
		"export FEATURE_FLAG_NEW_UI=true;",
		// PATH should have all 3 prepended dirs from _.path.
		"/Users/.../examples/basic/bin:",
		"/Users/.../examples/basic/node_modules/.bin:",
		"/Users/.../examples/basic/vendor/bin:",
		`export ALLOWED_ORIGINS='[http://localhost:3000, https://app.example.com]';`,
	}
	for _, want := range mustContain {
		if !strings.Contains(got, want) {
			t.Errorf("basic missing %q\n---\ngot:\n%s", want, got)
		}
	}
}

// TestGoldenMultiProfileDev verifies dev profile invariants.
func TestGoldenMultiProfileDev(t *testing.T) {
	got := runEvalForTest(t, "../../examples/multi-profile", "dev", "bash")
	got = normalizePath(got, resolveConfigDir(t, "../../examples/multi-profile"), "/Users/.../examples/multi-profile")

	mustContain := []string{
		"export SERVICE_NAME=myapp;",                              // base
		"export DATABASE_URL=postgres://localhost:5432/mydb_dev;", // dev override
		"export DATABASE_PASSWORD=dev-password;",                  // dev override
		"export LOG_LEVEL=info;",                                  // base (not dev's "debug" — debug is not in [env], only [env.*])
		"export METRICS_ENABLED=true;",                            // base
		"export SEED_DATA=true;",                                  // dev only
		"export DEBUG=true;",                                      // dev only
	}
	for _, want := range mustContain {
		if !strings.Contains(got, want) {
			t.Errorf("multi-profile-dev missing %q\n---\ngot:\n%s", want, got)
		}
	}
}

// TestGoldenMonorepo verifies that root + service configs are merged correctly.
func TestGoldenMonorepo(t *testing.T) {
	got := runEvalForTest(t, "../../examples/monorepo/services/api", "", "bash")
	got = normalizePath(got, resolveConfigDir(t, "../../examples/monorepo/services/api"), "/Users/.../examples/monorepo/services/api")

	// Check key invariants without exact-string match (PATH order varies by env).
	mustContain := []string{
		"export MONOREPO_ROOT=/Users/.../examples/monorepo/services/api;",
		"export INFRA_ENV=shared-vpc-1;",
		"export LOG_FORMAT=json;",
		"export LOG_LEVEL=debug;",
		"export SERVICE_NAME=api;",
		"export SERVICE_PORT=8080;",
	}
	for _, want := range mustContain {
		if !strings.Contains(got, want) {
			t.Errorf("monorepo missing line %q\n---\ngot:\n%s", want, got)
		}
	}
}

// resolveConfigDir makes the relative config path absolute, so the
// normalize step can replace the actual on-disk path with the test's
// portable placeholder regardless of the host OS.
func resolveConfigDir(t *testing.T, rel string) string {
	t.Helper()
	abs, err := filepath.Abs(rel)
	if err != nil {
		t.Fatal(err)
	}
	return abs
}

// normalizePath replaces the absolute configDir prefix in the script with
// a stable placeholder, so golden tests work across machines (macOS dev +
// Linux CI runner). The placeholder has the same trailing sub-path as the
// configDir, e.g.
//
//	configDir = "/home/runner/work/envee/envee/examples/monorepo/services/api"
//	placeholder = "/Users/.../examples/monorepo/services/api"
//
// Any sub-path under configDir (e.g. ".../examples/monorepo/services/api/foo")
// is preserved verbatim — only the prefix is rewritten.
func normalizePath(s, configDir, placeholder string) string {
	// Replace any occurrence of the absolute configDir prefix with the
	// placeholder. Walk the configDir from longest to shortest so that
	// nested paths are replaced at the deepest level first.
	return strings.ReplaceAll(s, configDir, placeholder)
}
