package plugin

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// pluginDir holds the fake plugin binaries, installed under several
// envee-plugin-<name> aliases. Set by TestMain.
var pluginDir string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "envee-plugin-test-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)
	pluginDir = dir

	ext := ""
	if runtime.GOOS == "windows" {
		ext = ".exe"
	}
	// One binary, several names: discovery is by filename, and the tests use
	// distinct names so a failure mode can be pinned to a source.
	primary := filepath.Join(dir, "envee-plugin-fake"+ext)
	build := exec.Command("go", "build", "-o", primary, "./testdata/fakeplugin")
	build.Stderr = os.Stderr
	if buildErr := build.Run(); buildErr != nil {
		panic("building the fake plugin failed: " + buildErr.Error())
	}
	data, err := os.ReadFile(primary)
	if err != nil {
		panic(err)
	}
	for _, alias := range []string{"alpha", "beta"} {
		if err := os.WriteFile(filepath.Join(dir, "envee-plugin-"+alias+ext), data, 0o755); err != nil {
			panic(err)
		}
	}
	// A non-executable file and an unrelated binary must both be ignored.
	_ = os.WriteFile(filepath.Join(dir, "envee-plugin-notexec"), []byte("#!/bin/sh\n"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "unrelated-binary"), data, 0o755)

	os.Exit(m.Run())
}

// withPluginPath points $PATH exclusively at the fake plugin directory, so a
// developer's real plugins cannot influence the result.
func withPluginPath(t *testing.T) {
	t.Helper()
	t.Setenv("PATH", pluginDir)
}

func TestNewExecPluginNotFound(t *testing.T) {
	withPluginPath(t)
	if _, err := NewExecPlugin("definitely-not-installed"); err == nil {
		t.Fatal("expected an error for a plugin that is not on PATH")
	}
}

func TestFetchMetadata(t *testing.T) {
	withPluginPath(t)
	p, err := NewExecPlugin("fake")
	if err != nil {
		t.Fatal(err)
	}
	md, err := p.FetchMetadata(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if md.Name != "fake" || md.Version != "9.9.9" || md.APIVersion != 1 {
		t.Errorf("unexpected metadata: %+v", md)
	}
}

func TestFetchMetadataIsCached(t *testing.T) {
	withPluginPath(t)
	p, err := NewExecPlugin("fake")
	if err != nil {
		t.Fatal(err)
	}
	if _, fetchErr := p.FetchMetadata(context.Background()); fetchErr != nil {
		t.Fatal(fetchErr)
	}
	// Break the binary path; a cached result must still come back.
	p.Path = filepath.Join(pluginDir, "does-not-exist")
	md, err := p.FetchMetadata(context.Background())
	if err != nil {
		t.Fatalf("metadata should be cached after the first call: %v", err)
	}
	if md.Name != "fake" {
		t.Errorf("got %+v", md)
	}
}

func TestFetchMetadataGarbageOutput(t *testing.T) {
	withPluginPath(t)
	t.Setenv("FAKE_PLUGIN_MODE", "garbage")
	p, _ := NewExecPlugin("fake")
	if _, err := p.FetchMetadata(context.Background()); err == nil {
		t.Fatal("non-JSON metadata should be an error, not silently accepted")
	}
}

func TestFetchMetadataNonZeroExit(t *testing.T) {
	withPluginPath(t)
	t.Setenv("FAKE_PLUGIN_MODE", "exit_nonzero")
	p, _ := NewExecPlugin("fake")
	if _, err := p.FetchMetadata(context.Background()); err == nil {
		t.Fatal("a plugin exiting non-zero should be an error")
	}
}

func TestResolveSecret(t *testing.T) {
	withPluginPath(t)
	p, _ := NewExecPlugin("fake")
	got, err := p.ResolveSecret(context.Background(), "fake", "my/ref")
	if err != nil {
		t.Fatal(err)
	}
	if got != "resolved:my/ref" {
		t.Errorf("got %q", got)
	}
}

func TestResolveSecretValueTypes(t *testing.T) {
	cases := map[string]string{
		"int_value":  "42",
		"bool_value": "true",
		"json_value": `{"a":1}`,
		"null_value": "",
	}
	for mode, want := range cases {
		t.Run(mode, func(t *testing.T) {
			withPluginPath(t)
			t.Setenv("FAKE_PLUGIN_MODE", mode)
			p, _ := NewExecPlugin("fake")
			got, err := p.ResolveSecret(context.Background(), "fake", "r")
			if err != nil {
				t.Fatal(err)
			}
			if got != want {
				t.Errorf("got %q, want %q", got, want)
			}
		})
	}
}

func TestResolveSecretErrorResponse(t *testing.T) {
	withPluginPath(t)
	t.Setenv("FAKE_PLUGIN_MODE", "error_response")
	p, _ := NewExecPlugin("fake")
	_, err := p.ResolveSecret(context.Background(), "fake", "missing/ref")
	if err == nil {
		t.Fatal("expected an error")
	}
	// The plugin's own message must survive; otherwise the user is told
	// nothing about why the secret could not be resolved.
	if !strings.Contains(err.Error(), "E_NOT_FOUND") || !strings.Contains(err.Error(), "missing/ref") {
		t.Errorf("error lost the plugin's detail: %v", err)
	}
}

func TestResolveSecretNonOKStatus(t *testing.T) {
	withPluginPath(t)
	t.Setenv("FAKE_PLUGIN_MODE", "status_not_ok")
	p, _ := NewExecPlugin("fake")
	if _, err := p.ResolveSecret(context.Background(), "fake", "r"); err == nil {
		t.Fatal("a non-ok status must not be treated as success")
	}
}

func TestResolveSecretGarbageOutput(t *testing.T) {
	withPluginPath(t)
	t.Setenv("FAKE_PLUGIN_MODE", "garbage")
	p, _ := NewExecPlugin("fake")
	if _, err := p.ResolveSecret(context.Background(), "fake", "r"); err == nil {
		t.Fatal("non-JSON output must not be treated as a value")
	}
}

// A plugin that never returns must not hang the shell hook forever.
func TestResolveSecretHonoursContextDeadline(t *testing.T) {
	withPluginPath(t)
	t.Setenv("FAKE_PLUGIN_MODE", "hang")
	p, _ := NewExecPlugin("fake")

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := p.ResolveSecret(ctx, "fake", "r")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected the call to fail once the deadline passed")
	}
	if elapsed > 10*time.Second {
		t.Errorf("call took %s; the context deadline was not honoured", elapsed)
	}
}

func TestDiscoverPaths(t *testing.T) {
	withPluginPath(t)
	names := map[string]bool{}
	for _, p := range DiscoverPaths() {
		names[PluginName(p)] = true
	}
	for _, want := range []string{"fake", "alpha", "beta"} {
		if !names[want] {
			t.Errorf("discovery missed %q (found %v)", want, names)
		}
	}
	// Not executable on either platform: no exec bit on Unix, and no
	// PATHEXT extension on Windows.
	if names["notexec"] {
		t.Error("a non-executable file was reported as a plugin")
	}
	if names[""] || names["unrelated-binary"] {
		t.Error("a binary without the envee-plugin- prefix was reported as a plugin")
	}
}

func TestPluginName(t *testing.T) {
	cases := map[string]string{
		"/usr/local/bin/envee-plugin-op": "op",
		"envee-plugin-vault":             "vault",
		"/bin/envee-plugin-":             "",
		"/bin/not-a-plugin":              "",
	}
	for in, want := range cases {
		if got := PluginName(in); got != want {
			t.Errorf("PluginName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestExeName(t *testing.T) {
	if got := ExeName("op"); got != "envee-plugin-op" {
		t.Errorf("got %q", got)
	}
	// Already-qualified names must not be prefixed twice.
	if got := ExeName("envee-plugin-op"); got != "envee-plugin-op" {
		t.Errorf("got %q", got)
	}
}

// --- dispatcher --------------------------------------------------------------

type stubResolver struct {
	value string
	err   error
	gotSo string
	gotRe string
}

func (s *stubResolver) ResolveSecret(_ context.Context, source, ref string) (string, error) {
	s.gotSo, s.gotRe = source, ref
	return s.value, s.err
}

func TestDispatcherRoutesBySource(t *testing.T) {
	a := &stubResolver{value: "from-a"}
	b := &stubResolver{value: "from-b"}
	d := NewDispatcher(map[string]SecretResolver{"a": a, "b": b})

	got, err := d.ResolveSecret(context.Background(), "b", "some/ref")
	if err != nil {
		t.Fatal(err)
	}
	if got != "from-b" {
		t.Errorf("routed to the wrong plugin: got %q", got)
	}
	if b.gotSo != "b" || b.gotRe != "some/ref" {
		t.Errorf("plugin received source=%q ref=%q", b.gotSo, b.gotRe)
	}
	if a.gotRe != "" {
		t.Error("the unrelated plugin was invoked")
	}
}

func TestDispatcherUnknownSource(t *testing.T) {
	d := NewDispatcher(map[string]SecretResolver{})
	_, err := d.ResolveSecret(context.Background(), "nope", "r")

	var lookupErr *PluginLookupError
	if !errors.As(err, &lookupErr) {
		t.Fatalf("expected a *PluginLookupError, got %T: %v", err, err)
	}
	if lookupErr.Source != "nope" {
		t.Errorf("error names source %q", lookupErr.Source)
	}
}

func TestDispatcherPropagatesPluginError(t *testing.T) {
	want := errors.New("upstream is down")
	d := NewDispatcher(map[string]SecretResolver{"a": &stubResolver{err: want}})
	if _, err := d.ResolveSecret(context.Background(), "a", "r"); !errors.Is(err, want) {
		t.Errorf("plugin error was swallowed: %v", err)
	}
}
