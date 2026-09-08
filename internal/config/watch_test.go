package config

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// `watch` is written inside the [env] table and isMetaKey keeps it from
// becoming a variable — but nothing ever read it, so WatchedPaths stayed nil
// and the documented "reload when these change" behaviour did not exist.
func TestParseWatch(t *testing.T) {
	cases := map[string]struct {
		body string
		want []string
	}{
		"list": {"schema = \"envee/v1\"\n\n[env]\nA = \"1\"\nwatch = [\"Cargo.toml\", \"package.json\"]\n",
			[]string{"Cargo.toml", "package.json"}},
		"single string": {"schema = \"envee/v1\"\n\n[env]\nwatch = \"go.mod\"\n",
			[]string{"go.mod"}},
		"absent": {"schema = \"envee/v1\"\n\n[env]\nA = \"1\"\n", nil},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "envee.toml")
			if err := os.WriteFile(path, []byte(tc.body), 0o644); err != nil {
				t.Fatal(err)
			}
			cfg, err := Parse(path)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(cfg.WatchedPaths, tc.want) {
				t.Errorf("WatchedPaths = %#v, want %#v", cfg.WatchedPaths, tc.want)
			}
			// And it must not leak into the environment as a variable.
			if _, leaked := cfg.Env["watch"]; leaked {
				t.Error("`watch` must not remain in Env")
			}
		})
	}
}

// The real example must parse, since it is what users copy.
func TestParseWatchInExample(t *testing.T) {
	cfg, err := Parse("../../examples/basic/envee.toml")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"Cargo.toml", "package.json"}
	if !reflect.DeepEqual(cfg.WatchedPaths, want) {
		t.Errorf("WatchedPaths = %#v, want %#v", cfg.WatchedPaths, want)
	}
}
