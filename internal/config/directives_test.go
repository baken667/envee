package config

import (
	"os"
	"path/filepath"
	"testing"
)

func parseInline(t *testing.T, body string) *Config {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "envee.toml")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := Parse(path)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return cfg
}

// The table form documented in ADR-0004 was not handled by directivesFromMap
// at all, so it was silently discarded: the variable never appeared, status
// reported "_.secret: 0 entries", and check found nothing to complain about.
// Only the shorthand under [env] worked, which is why it went unnoticed.
func TestParseSecretTableForm(t *testing.T) {
	cfg := parseInline(t, `
schema = "envee/v1"

[env]
APP = "x"

[env._.secret.DB_PASSWORD]
source = "vault"
ref = "secret/data/db#password"
redact = true
required = true
`)

	got, ok := cfg.Directives.Secret["DB_PASSWORD"]
	if !ok {
		t.Fatalf("[env._.secret.NAME] was dropped; Secret = %#v", cfg.Directives.Secret)
	}
	if got.Source != "vault" || got.Ref != "secret/data/db#password" {
		t.Errorf("got %+v", got)
	}
	if !got.Redact || !got.Required {
		t.Errorf("flags lost: redact=%v required=%v", got.Redact, got.Required)
	}
}

func TestParseSecretOptionalFields(t *testing.T) {
	cfg := parseInline(t, `
schema = "envee/v1"

[env._.secret.TOKEN]
source = "op"
ref = "op://Dev/GitHub/token"
account = "work"
vault = "Dev"
profile = "staging"
`)
	got := cfg.Directives.Secret["TOKEN"]
	if got.Account != "work" || got.Vault != "Dev" || got.Profile != "staging" {
		t.Errorf("optional fields lost: %+v", got)
	}
}

// Both spellings must land in the same place for SecretRefs, since that is
// what the trust summary, `envee check` and plugin loading all consult.
func TestSecretRefsCoversBothForms(t *testing.T) {
	cfg := parseInline(t, `
schema = "envee/v1"

[env]
SHORTHAND = { source = "env", ref = "A" }

[env._.secret.TABLE_FORM]
source = "vault"
ref = "B"
`)
	refs := cfg.SecretRefs()
	if len(refs) != 2 {
		t.Fatalf("expected both forms, got %#v", refs)
	}
	if refs["SHORTHAND"].Source != "env" || refs["TABLE_FORM"].Source != "vault" {
		t.Errorf("got %#v", refs)
	}
}

// _.source was dropped for the same reason.
func TestParseSourceDirective(t *testing.T) {
	cases := map[string]string{
		"bare string": `
schema = "envee/v1"

[env]
_.source = "setup.sh"
`,
		"list of tables": `
schema = "envee/v1"

[env]
_.source = [ { path = "setup.sh", shell = "bash", redact = true } ]
`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := parseInline(t, body)
			if len(cfg.Directives.Source) != 1 {
				t.Fatalf("_.source was dropped: %#v", cfg.Directives.Source)
			}
			if cfg.Directives.Source[0].Path != "setup.sh" {
				t.Errorf("got %+v", cfg.Directives.Source[0])
			}
		})
	}
}

// A config with no directives at all must not gain phantom ones.
func TestParseNoDirectives(t *testing.T) {
	cfg := parseInline(t, "schema = \"envee/v1\"\n\n[env]\nA = \"1\"\n")
	if len(cfg.Directives.Secret) != 0 || len(cfg.Directives.Source) != 0 {
		t.Errorf("unexpected directives: %#v", cfg.Directives)
	}
	if len(cfg.SecretRefs()) != 0 {
		t.Errorf("SecretRefs should be empty: %#v", cfg.SecretRefs())
	}
}
