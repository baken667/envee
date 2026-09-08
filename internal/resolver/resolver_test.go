package resolver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeConfig(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// The upward walk must visit EVERY ancestor directory. It previously advanced
// twice per iteration (a `for ... ; dir = filepath.Dir(dir)` post statement
// plus an assignment at the end of the body), so a config in the immediate
// parent directory was never discovered — which broke the monorepo layout the
// README advertises.
func TestDiscoverVisitsEveryAncestor(t *testing.T) {
	root := t.TempDir()
	deep := filepath.Join(root, "a", "b", "c")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}

	levels := []string{
		root,
		filepath.Join(root, "a"),
		filepath.Join(root, "a", "b"),
		filepath.Join(root, "a", "b", "c"),
	}
	for i, dir := range levels {
		writeConfig(t, filepath.Join(dir, "envee.toml"), "schema = \"envee/v1\"\n\n[env]\nLEVEL"+string(rune('0'+i))+" = \"yes\"\n")
	}

	r, err := New(deep)
	if err != nil {
		t.Fatal(err)
	}
	r.SetStopAtRoot(root)

	files, err := r.Discover()
	if err != nil {
		t.Fatal(err)
	}

	for _, dir := range levels {
		want := filepath.Join(dir, "envee.toml")
		found := false
		for _, f := range files {
			if f == want {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Discover skipped %s\n  got: %v", want, files)
		}
	}
}

func TestDiscoverPriorityOrder(t *testing.T) {
	dir := t.TempDir()
	writeConfig(t, filepath.Join(dir, "envee.toml"), "schema = \"envee/v1\"\n")
	writeConfig(t, filepath.Join(dir, "envee.local.toml"), "schema = \"envee/v1\"\n")
	writeConfig(t, filepath.Join(dir, "envee.d", "10-a.toml"), "schema = \"envee/v1\"\n")
	writeConfig(t, filepath.Join(dir, "envee.d", "20-b.toml"), "schema = \"envee/v1\"\n")

	r, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	r.SetStopAtRoot(dir)

	files, err := r.Discover()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		filepath.Join(dir, "envee.local.toml"),
		filepath.Join(dir, "envee.toml"),
		filepath.Join(dir, "envee.d", "10-a.toml"),
		filepath.Join(dir, "envee.d", "20-b.toml"),
	}
	if len(files) < len(want) {
		t.Fatalf("got %d files, want at least %d: %v", len(files), len(want), files)
	}
	for i, w := range want {
		if files[i] != w {
			t.Errorf("files[%d] = %s, want %s\n  all: %v", i, files[i], w, files)
		}
	}
}

// The global config directory must be absolute. It used to be built with
// filepath.Join(os.Getenv("XDG_CONFIG_HOME"), "envee"), which yields the
// RELATIVE path "envee" when the variable is unset — so the real global
// config was never read and any ./envee directory was loaded instead.
func TestGlobalConfigDirIsAbsolute(t *testing.T) {
	r, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if r.configDir == "" {
		t.Fatal("configDir is empty")
	}
	if !filepath.IsAbs(r.configDir) {
		t.Errorf("configDir = %q, want an absolute path", r.configDir)
	}
	if !strings.HasSuffix(r.configDir, "envee") {
		t.Errorf("configDir = %q, want it to end in envee", r.configDir)
	}
}

// Every file that contributes to a merged Config must be recorded in
// Sources, because that is what the trust gate iterates. Recording only the
// first file let envee.local.toml and envee.d/*.toml be applied without ever
// being approved.
func TestLoadAllRecordsEverySource(t *testing.T) {
	dir := t.TempDir()
	writeConfig(t, filepath.Join(dir, "envee.toml"), "schema = \"envee/v1\"\n\n[env]\nA = \"1\"\n")
	writeConfig(t, filepath.Join(dir, "envee.local.toml"), "schema = \"envee/v1\"\n\n[env]\nB = \"2\"\n")
	writeConfig(t, filepath.Join(dir, "envee.d", "10-c.toml"), "schema = \"envee/v1\"\n\n[env]\nC = \"3\"\n")

	r, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	r.SetStopAtRoot(dir)

	cfg, err := r.LoadAll()
	if err != nil {
		t.Fatal(err)
	}

	got := make(map[string]string, len(cfg.Sources))
	for _, src := range cfg.Sources {
		if src.Hash == "" {
			t.Errorf("source %s has an empty hash", src.Path)
		}
		got[src.Path] = src.Hash
	}

	for _, want := range []string{
		filepath.Join(dir, "envee.toml"),
		filepath.Join(dir, "envee.local.toml"),
		filepath.Join(dir, "envee.d", "10-c.toml"),
	} {
		if _, ok := got[want]; !ok {
			t.Errorf("Sources is missing %s\n  got: %v", want, cfg.Sources)
		}
	}

	// Sanity: the merge itself still works.
	for _, k := range []string{"A", "B", "C"} {
		if _, ok := cfg.Env[k]; !ok {
			t.Errorf("merged config is missing env key %s", k)
		}
	}
}
