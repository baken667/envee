package config

import (
	"strings"
	"testing"
)

func TestParseBasic(t *testing.T) {
	src := []byte(`
schema = "envee/v1"
profile = "dev"

[env]
DATABASE_URL = "postgres://localhost/mydb"
PORT = 5432
DEBUG = true
`)
	cfg, err := ParseBytes("/tmp/test/envee.toml", src)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Schema != "envee/v1" {
		t.Errorf("Schema = %q", cfg.Schema)
	}
	if cfg.Profile != "dev" {
		t.Errorf("Profile = %q", cfg.Profile)
	}
	if cfg.Env["DATABASE_URL"] != "postgres://localhost/mydb" {
		t.Errorf("DATABASE_URL = %v", cfg.Env["DATABASE_URL"])
	}
	// BurntSushi decodes integers to int64
	if v, ok := cfg.Env["PORT"].(int64); !ok || v != 5432 {
		t.Errorf("PORT = %v (%T)", cfg.Env["PORT"], cfg.Env["PORT"])
	}
	if cfg.Env["DEBUG"] != true {
		t.Errorf("DEBUG = %v", cfg.Env["DEBUG"])
	}
}

func TestParseFile(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/envee.toml"
	src := `schema = "envee/v1"
[env]
KEY = "value"
`
	if err := writeFile(path, src); err != nil {
		t.Fatal(err)
	}
	cfg, err := Parse(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Env["KEY"] != "value" {
		t.Errorf("KEY = %v", cfg.Env["KEY"])
	}
	if !strings.HasPrefix(cfg.FileHash, "sha256:") {
		t.Errorf("FileHash = %q, want sha256:...", cfg.FileHash)
	}
}

func TestParseProfiles(t *testing.T) {
	src := []byte(`
schema = "envee/v1"
profile = "dev"

[env]
KEY = "base"

[profiles.dev]
KEY = "dev-value"

[profiles.prod]
KEY = "prod-value"
required = ["KEY"]
`)
	cfg, err := ParseBytes("/tmp/envee.toml", src)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := cfg.Profiles["dev"]; !ok {
		t.Error("missing dev profile")
	}
	if _, ok := cfg.Profiles["prod"]; !ok {
		t.Error("missing prod profile")
	}
	if cfg.Profiles["prod"].Required[0] != "KEY" {
		t.Errorf("prod required = %v", cfg.Profiles["prod"].Required)
	}
}

func TestParseDirectives(t *testing.T) {
	src := []byte(`
schema = "envee/v1"

[env]
KEY = "value"

[env._]
path = ["./bin", "./node_modules/.bin"]
file = ".env"
`)
	cfg, err := ParseBytes("/tmp/envee.toml", src)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Directives == nil {
		t.Fatal("Directives is nil")
	}
	if len(cfg.Directives.Path) != 2 {
		t.Errorf("Path directives = %d, want 2", len(cfg.Directives.Path))
	}
	if len(cfg.Directives.File) != 1 {
		t.Errorf("File directives = %d, want 1", len(cfg.Directives.File))
	}
}

func TestParseInvalid(t *testing.T) {
	src := []byte(`this is not = "valid" toml = =`)
	_, err := ParseBytes("/tmp/envee.toml", src)
	if err == nil {
		t.Error("expected error for invalid TOML")
	}
}

// writeFile is a small helper to avoid the import cycle with os in tests.
func writeFile(path, content string) error {
	return writeFileImpl(path, content)
}
