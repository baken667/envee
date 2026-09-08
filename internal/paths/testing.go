package paths

import (
	"testing"

	"github.com/adrg/xdg"
)

// IsolateForTest points every envee path at a temporary directory for the
// duration of a test.
//
// t.Setenv alone is NOT enough: adrg/xdg reads the environment once at package
// initialisation and caches it, so a test that only sets $XDG_DATA_HOME still
// reads and WRITES the developer's real trust store. This was not theoretical
// -- it happened, and a test wrote an entry into a real store before this
// helper existed.
//
// Returns the temporary root, so a test can inspect what was written.
func IsolateForTest(t *testing.T) string {
	t.Helper()

	root := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", root+"/config")
	t.Setenv("XDG_DATA_HOME", root+"/data")
	t.Setenv("XDG_CACHE_HOME", root+"/cache")
	t.Setenv("XDG_RUNTIME_DIR", root+"/run")

	// Re-read the environment we just set, then restore the real values for
	// whatever runs after this test.
	xdg.Reload()
	t.Cleanup(xdg.Reload)

	return root
}
