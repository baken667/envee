package directive

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/baken667/envee/internal/config"
)

func TestApplyBasicTOML(t *testing.T) {
	dir := t.TempDir()
	src := `
schema = "envee/v1"
profile = "dev"

[env]
SERVICE_NAME = "myapp"
DATABASE_URL = "postgres://localhost/db"
PORT = 5432
DEBUG = true
`
	path := filepath.Join(dir, "envee.toml")
	if err := os.WriteFile(path, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Parse(path)
	if err != nil {
		t.Fatal(err)
	}

	res, err := Apply(context.Background(), cfg, ApplyOptions{
		ConfigRoot: dir,
		Profile:    "dev",
		Cwd:        dir,
		OSEnv:      map[string]string{},
	}, nil)
	if err != nil {
		t.Fatal(err)
	}

	if v, _ := res.Env.Get("SERVICE_NAME"); v != "myapp" {
		t.Errorf("SERVICE_NAME = %q", v)
	}
	if v, _ := res.Env.Get("DATABASE_URL"); v != "postgres://localhost/db" {
		t.Errorf("DATABASE_URL = %q", v)
	}
	if v, _ := res.Env.Get("PORT"); v != "5432" {
		t.Errorf("PORT = %q", v)
	}
	if v, _ := res.Env.Get("DEBUG"); v != "true" {
		t.Errorf("DEBUG = %q", v)
	}
}

func TestApplyWithDotenvFile(t *testing.T) {
	dir := t.TempDir()
	tomlSrc := `
schema = "envee/v1"

[env]
KEY_FROM_TOML = "from-toml"

[env._]
file = ".env"
`
	if err := os.WriteFile(filepath.Join(dir, "envee.toml"), []byte(tomlSrc), 0o644); err != nil {
		t.Fatal(err)
	}
	dotenvSrc := "KEY_FROM_DOTENV=from-dotenv\nOTHER=val\n"
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(dotenvSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := config.Parse(filepath.Join(dir, "envee.toml"))
	if err != nil {
		t.Fatal(err)
	}
	res, err := Apply(context.Background(), cfg, ApplyOptions{
		ConfigRoot: dir,
		OSEnv:      map[string]string{},
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := res.Env.Get("KEY_FROM_TOML"); v != "from-toml" {
		t.Errorf("KEY_FROM_TOML = %q, want from-toml", v)
	}
	if v, _ := res.Env.Get("KEY_FROM_DOTENV"); v != "from-dotenv" {
		t.Errorf("KEY_FROM_DOTENV = %q, want from-dotenv", v)
	}
}

func TestApplyWithPath(t *testing.T) {
	dir := t.TempDir()
	src := `
schema = "envee/v1"

[env]
[env._]
path = ["./bin", "./node_modules/.bin"]
`
	if err := os.WriteFile(filepath.Join(dir, "envee.toml"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}

	cfg, err := config.Parse(filepath.Join(dir, "envee.toml"))
	if err != nil {
		t.Fatal(err)
	}
	res, err := Apply(context.Background(), cfg, ApplyOptions{
		ConfigRoot: dir,
		OSEnv:      map[string]string{"PATH": "/usr/bin"},
	}, nil)
	if err != nil {
		t.Fatal(err)
	}

	if len(res.PathPrepend) != 2 {
		t.Errorf("PathPrepend = %v, want 2 entries", res.PathPrepend)
	}
	// Both should be absolute (joined with configRoot).
	for _, p := range res.PathPrepend {
		if !filepath.IsAbs(p) {
			t.Errorf("path not absolute: %q", p)
		}
	}
}

func TestApplyWithTemplate(t *testing.T) {
	dir := t.TempDir()
	src := `
schema = "envee/v1"
profile = "dev"

[env]
LOG_PATH = "{{config_root}}/logs/{{profile}}.log"
DATABASE_URL = "postgres://{{env.HOST}}/{{env.DB}}"
`
	if err := os.WriteFile(filepath.Join(dir, "envee.toml"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := config.Parse(filepath.Join(dir, "envee.toml"))
	if err != nil {
		t.Fatal(err)
	}
	res, err := Apply(context.Background(), cfg, ApplyOptions{
		ConfigRoot: dir,
		Profile:    "dev",
		OSEnv:      map[string]string{"HOST": "localhost", "DB": "mydb"},
	}, nil)
	if err != nil {
		t.Fatal(err)
	}

	wantPath := filepath.Join(dir, "logs", "dev.log")
	if v, _ := res.Env.Get("LOG_PATH"); v != wantPath {
		t.Errorf("LOG_PATH = %q, want %q", v, wantPath)
	}
	if v, _ := res.Env.Get("DATABASE_URL"); v != "postgres://localhost/mydb" {
		t.Errorf("DATABASE_URL = %q", v)
	}
}

func TestApplyProfile(t *testing.T) {
	dir := t.TempDir()
	src := `
schema = "envee/v1"
profile = "dev"

[env]
SERVICE_NAME = "myapp"

[profiles.dev]
DATABASE_URL = "postgres://localhost/dev"

[profiles.prod]
DATABASE_URL = "postgres://prod/db"
LOG_LEVEL = "warn"
`
	if err := os.WriteFile(filepath.Join(dir, "envee.toml"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := config.Parse(filepath.Join(dir, "envee.toml"))
	if err != nil {
		t.Fatal(err)
	}

	// dev
	res, err := Apply(context.Background(), cfg, ApplyOptions{
		ConfigRoot: dir,
		Profile:    "dev",
		OSEnv:      map[string]string{},
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := res.Env.Get("DATABASE_URL"); v != "postgres://localhost/dev" {
		t.Errorf("dev DATABASE_URL = %q", v)
	}
	if v, _ := res.Env.Get("LOG_LEVEL"); v != "" {
		t.Errorf("dev LOG_LEVEL = %q, want empty", v)
	}

	// prod
	res, err = Apply(context.Background(), cfg, ApplyOptions{
		ConfigRoot: dir,
		Profile:    "prod",
		OSEnv:      map[string]string{},
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := res.Env.Get("DATABASE_URL"); v != "postgres://prod/db" {
		t.Errorf("prod DATABASE_URL = %q", v)
	}
	if v, _ := res.Env.Get("LOG_LEVEL"); v != "warn" {
		t.Errorf("prod LOG_LEVEL = %q", v)
	}
}

func TestApplyCycleDetected(t *testing.T) {
	dir := t.TempDir()
	src := `
schema = "envee/v1"
[env]
A = "{{env.B}}"
B = "{{env.A}}"
`
	if err := os.WriteFile(filepath.Join(dir, "envee.toml"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Parse(filepath.Join(dir, "envee.toml"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = Apply(context.Background(), cfg, ApplyOptions{
		ConfigRoot: dir,
		OSEnv:      map[string]string{},
	}, nil)
	if err == nil {
		t.Error("expected cycle error, got nil")
	}
	if !strings.Contains(err.Error(), "circular") && !strings.Contains(err.Error(), "E007") {
		t.Errorf("expected cycle error, got: %v", err)
	}
}

func TestApplySecretShorthand(t *testing.T) {
	dir := t.TempDir()
	src := `
schema = "envee/v1"
[env]
DATABASE_PASSWORD = { source = "env", ref = "DB_PASS", redact = true, required = true }
`
	if err := os.WriteFile(filepath.Join(dir, "envee.toml"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Parse(filepath.Join(dir, "envee.toml"))
	if err != nil {
		t.Fatal(err)
	}

	// Without a plugin resolver, secret shorthand should still create a directive entry.
	res, err := Apply(context.Background(), cfg, ApplyOptions{
		ConfigRoot: dir,
		OSEnv:      map[string]string{},
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	// The secret should be marked as redacted (placeholder).
	meta, ok := res.Env.GetWithMeta("DATABASE_PASSWORD")
	if !ok {
		t.Fatal("DATABASE_PASSWORD not in env")
	}
	if !meta.Redacted {
		t.Error("DATABASE_PASSWORD should be redacted")
	}
}
