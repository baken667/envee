package trust

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/baken667/envee/internal/config"
)

func TestBuildSummary(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "envee.toml")
	src := `
schema = "envee/v1"
profile = "dev"

[env]
SERVICE_NAME = "myapp"
DATABASE_URL = "postgres://localhost/db"
API_KEY = { value = "dev-key", redact = true }
PORT = 5432
DEBUG = true

[env._]
path = ["./bin", "./node_modules/.bin"]
file = ".env"
`
	if err := os.WriteFile(path, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Parse(path)
	if err != nil {
		t.Fatal(err)
	}

	summary := BuildSummary(cfg)

	if summary.Path != path {
		t.Errorf("Path = %q", summary.Path)
	}
	if summary.Profile != "dev" {
		t.Errorf("Profile = %q", summary.Profile)
	}
	if summary.Hash == "" {
		t.Error("Hash is empty")
	}
	if len(summary.EnvVars) != 4 {
		t.Errorf("EnvVars = %v, want 4", summary.EnvVars)
	}
	if len(summary.RedactedVars) != 1 {
		t.Errorf("RedactedVars = %v, want 1", summary.RedactedVars)
	}
	if summary.RedactedVars[0] != "API_KEY" {
		t.Errorf("RedactedVars[0] = %q, want API_KEY", summary.RedactedVars[0])
	}
	if len(summary.PathAdds) != 2 {
		t.Errorf("PathAdds = %v, want 2", summary.PathAdds)
	}
	if len(summary.Files) != 1 {
		t.Errorf("Files = %v, want 1", summary.Files)
	}
}

func TestSummaryString(t *testing.T) {
	summary := &Summary{
		Path:    "/tmp/test",
		Hash:    "sha256:abc",
		Schema:  "envee/v1",
		Profile: "dev",
		EnvVars: []string{"X", "Y"},
	}
	out := summary.String()
	if out == "" {
		t.Error("empty summary string")
	}
	// Just check key substrings.
	for _, want := range []string{"/tmp/test", "envee/v1", "Env vars:", "sha256:abc"} {
		if !contains(out, want) {
			t.Errorf("summary missing %q", want)
		}
	}
}

func TestNameLooksSensitive(t *testing.T) {
	tests := map[string]bool{
		"DATABASE_URL":   false,
		"API_KEY":        true,
		"GH_TOKEN":       true,
		"AWS_SECRET_KEY": true,
		"PASSWORD":       true,
		"AUTHORIZATION":  true,
		"LOG_LEVEL":      false,
	}
	for name, want := range tests {
		got := nameLooksSensitive(name)
		if got != want {
			t.Errorf("nameLooksSensitive(%q) = %v, want %v", name, got, want)
		}
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
