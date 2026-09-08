package paths

import (
	"path/filepath"
	"strings"
	"testing"
)

// Every path envee uses must be absolute. The resolver previously built its
// config directory from a raw $XDG_CONFIG_HOME, which yields a relative path
// when the variable is unset -- so envee read a directory in the user's cwd
// instead of their home. These assertions are cheap insurance against the
// same mistake here.
func TestAllPathsAreAbsolute(t *testing.T) {
	cases := map[string]string{
		"Config":              Config(),
		"Data":                Data(),
		"Cache":               Cache(),
		"Runtime":             Runtime(),
		"TrustStore":          TrustStore(),
		"PluginMetadataCache": PluginMetadataCache(),
		"Socket":              Socket(),
		"LockFile":            LockFile(),
	}
	for name, p := range cases {
		if p == "" {
			t.Errorf("%s() is empty", name)
			continue
		}
		if !filepath.IsAbs(p) {
			t.Errorf("%s() = %q, want an absolute path", name, p)
		}
	}
}

// Every path must sit inside a per-application directory. Runtime() used to
// return the bare XDG runtime directory, so the daemon socket and lock file
// were written next to every other application's files.
func TestAllPathsAreScopedToEnvee(t *testing.T) {
	for name, p := range map[string]string{
		"Config":              Config(),
		"Data":                Data(),
		"Cache":               Cache(),
		"Runtime":             Runtime(),
		"TrustStore":          TrustStore(),
		"PluginMetadataCache": PluginMetadataCache(),
		"Socket":              Socket(),
		"LockFile":            LockFile(),
	} {
		if !strings.Contains(p, string(filepath.Separator)+"envee") {
			t.Errorf("%s() = %q, want it under an envee directory", name, p)
		}
	}
}

func TestDerivedPathsNestUnderTheirParents(t *testing.T) {
	if got, want := TrustStore(), filepath.Join(Data(), "trust"); got != want {
		t.Errorf("TrustStore() = %q, want %q", got, want)
	}
	if got, want := PluginMetadataCache(), filepath.Join(Data(), "plugins"); got != want {
		t.Errorf("PluginMetadataCache() = %q, want %q", got, want)
	}
	if got, want := Socket(), filepath.Join(Runtime(), "envee.sock"); got != want {
		t.Errorf("Socket() = %q, want %q", got, want)
	}
	if got, want := LockFile(), filepath.Join(Runtime(), "envee.lock"); got != want {
		t.Errorf("LockFile() = %q, want %q", got, want)
	}
}

// ADR-0004 keeps the trust store out of the config directory so cloud sync
// tools that mirror ~/.config do not carry approvals between machines.
//
// This only holds where the platform actually separates the two. On macOS the
// XDG shim maps both ConfigHome and DataHome to ~/Library/Application Support,
// so they are the same directory and the separation is not available -- see
// the platform note in docs/adr/0004-trust-model.md.
func TestTrustStoreIsNotUnderConfig(t *testing.T) {
	if Config() == Data() {
		t.Skipf("this platform maps config and data to the same directory (%s)", Config())
	}
	if strings.HasPrefix(TrustStore(), Config()+string(filepath.Separator)) {
		t.Errorf("TrustStore() = %q is inside Config() = %q; see docs/adr/0004-trust-model.md",
			TrustStore(), Config())
	}
}
