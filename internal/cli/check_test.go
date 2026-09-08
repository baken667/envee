package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/baken667/envee/internal/config"
)

func parseTestConfig(t *testing.T, dir, body string) *config.Config {
	t.Helper()
	path := filepath.Join(dir, "envee.toml")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Parse(path)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return cfg
}

func findingsContain(findings []finding, level findingLevel, substr string) bool {
	for _, f := range findings {
		if f.Level == level && strings.Contains(f.Message, substr) {
			return true
		}
	}
	return false
}

func TestCheckFlagsMissingRequiredFile(t *testing.T) {
	dir := t.TempDir()
	cfg := parseTestConfig(t, dir, `
schema = "envee/v1"

[env]
A = "1"
_.file = [ { path = "nope.env", required = true } ]
`)
	got := checkConfig(cfg, nil, false)
	if !findingsContain(got, levelError, "nope.env") {
		t.Errorf("expected an error for the missing required file, got %+v", got)
	}
}

// An absent optional file is exactly what required = false means, so it must
// not be reported unless the user asked for --strict.
func TestCheckOptionalFileQuietByDefault(t *testing.T) {
	dir := t.TempDir()
	cfg := parseTestConfig(t, dir, `
schema = "envee/v1"

[env]
_.file = [ { path = ".env.local", required = false } ]
`)
	if got := checkConfig(cfg, nil, false); len(got) != 0 {
		t.Errorf("default mode should be quiet, got %+v", got)
	}
	if got := checkConfig(cfg, nil, true); !findingsContain(got, levelWarning, ".env.local") {
		t.Errorf("strict mode should report it, got %+v", got)
	}
}

func TestCheckRejectsReservedKeys(t *testing.T) {
	dir := t.TempDir()
	cfg := parseTestConfig(t, dir, `
schema = "envee/v1"

[env]
ENVEE_BYPASS_TRUST = "1"
`)
	if got := checkConfig(cfg, nil, false); !findingsContain(got, levelError, "reserved") {
		t.Errorf("expected an error for the reserved key, got %+v", got)
	}
}

func TestCheckDetectsTemplateCycle(t *testing.T) {
	dir := t.TempDir()
	cfg := parseTestConfig(t, dir, `
schema = "envee/v1"

[env]
A = "{{ B }}"
B = "{{ C }}"
C = "{{ A }}"
`)
	got := checkConfig(cfg, nil, false)
	if !findingsContain(got, levelError, "circular") {
		t.Errorf("expected a cycle error, got %+v", got)
	}
}

func TestCheckAcceptsAcyclicTemplates(t *testing.T) {
	dir := t.TempDir()
	cfg := parseTestConfig(t, dir, `
schema = "envee/v1"

[env]
A = "root"
B = "{{ A }}/sub"
C = "{{ B }}/leaf"
`)
	if got := checkConfig(cfg, nil, false); findingsContain(got, levelError, "circular") {
		t.Errorf("acyclic templates reported as a cycle: %+v", got)
	}
}

func TestCheckWarnsOnPlaintextCredential(t *testing.T) {
	dir := t.TempDir()
	cfg := parseTestConfig(t, dir, `
schema = "envee/v1"

[env]
STRIPE_SECRET_KEY = "sk_live_totally_real"
SERVICE_NAME = "myapp"
`)
	got := checkConfig(cfg, nil, false)
	if !findingsContain(got, levelWarning, "credential") {
		t.Errorf("expected a credential warning, got %+v", got)
	}
	for _, f := range got {
		if f.Key == "SERVICE_NAME" {
			t.Errorf("SERVICE_NAME should not be flagged: %+v", f)
		}
	}
}

func TestCheckRedactedCredentialIsFine(t *testing.T) {
	dir := t.TempDir()
	cfg := parseTestConfig(t, dir, `
schema = "envee/v1"

[env]
API_KEY = { value = "dev-only", redact = true }
`)
	if got := checkConfig(cfg, nil, false); len(got) != 0 {
		t.Errorf("a redacted credential should be clean, got %+v", got)
	}
}

func TestCheckUnknownSchema(t *testing.T) {
	dir := t.TempDir()
	cfg := parseTestConfig(t, dir, `
schema = "envee/v99"

[env]
A = "1"
`)
	if got := checkConfig(cfg, nil, false); !findingsContain(got, levelError, "unknown schema") {
		t.Errorf("expected an unknown-schema error, got %+v", got)
	}
}

func TestCheckMissingSecretPlugin(t *testing.T) {
	dir := t.TempDir()
	cfg := parseTestConfig(t, dir, `
schema = "envee/v1"

[env]
DB_PASSWORD = { source = "vault", ref = "secret/data/db#password", redact = true }
`)
	got := checkConfig(cfg, map[string]bool{"vault": false}, false)
	if !findingsContain(got, levelWarning, "no plugin found") {
		t.Errorf("expected a missing-plugin warning, got %+v", got)
	}
	if got := checkConfig(cfg, map[string]bool{"vault": true}, false); len(got) != 0 {
		t.Errorf("an installed plugin should be clean, got %+v", got)
	}
}
