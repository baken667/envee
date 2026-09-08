// Package paths centralizes filesystem-path conventions used across envee.
//
// All paths are derived from XDG Base Directory spec via adrg/xdg, so the
// behavior is consistent on macOS, Linux, and Windows.
//
// See docs/adr/0012-cross-platform.md.
package paths

import (
	"os"
	"path/filepath"

	"github.com/adrg/xdg"
)

// Config returns the per-user envee config directory.
//
//   - macOS/Linux:  $XDG_CONFIG_HOME/envee  (default: ~/.config/envee)
//   - Windows:      %APPDATA%/envee
func Config() string {
	return filepath.Join(xdg.ConfigHome, "envee")
}

// Data returns the per-user envee data directory (used for trust store,
// plugin metadata, etc.).
//
// We deliberately put the trust store here (not in Config) so it does not
// get synced to cloud storage (iCloud, Dropbox, syncthing) which often
// targets ~/.config. See docs/adr/0004-trust-model.md.
func Data() string {
	return filepath.Join(xdg.DataHome, "envee")
}

// Cache returns the per-user envee cache directory (completions cache, etc.).
func Cache() string {
	return filepath.Join(xdg.CacheHome, "envee")
}

// Runtime returns the per-user envee runtime directory (UNIX socket, PID file).
//
// The "envee" component matters: without it the socket and lock file land
// directly in the shared runtime directory (on macOS that is
// ~/Library/Application Support), next to every other application's files.
func Runtime() string {
	return filepath.Join(xdg.RuntimeDir, "envee")
}

// TrustStore returns the directory containing trust entries.
func TrustStore() string {
	return filepath.Join(Data(), "trust")
}

// PluginMetadataCache returns the directory containing cached plugin metadata.
func PluginMetadataCache() string {
	return filepath.Join(Data(), "plugins")
}

// Socket returns the path to the enveed UNIX socket.
func Socket() string {
	return filepath.Join(Runtime(), "envee.sock")
}

// LockFile returns the path to the daemon lock file (used for singleton detection).
func LockFile() string {
	return filepath.Join(Runtime(), "envee.lock")
}

// EnsureDirs creates all required envee directories with the correct permissions.
//
//   - Config/Data/Trust: 0755
//   - Socket directory:  0700 (XDG_RUNTIME_DIR is usually 0700 already)
func EnsureDirs() error {
	dirs := []string{
		Config(),
		Data(),
		Cache(),
		TrustStore(),
		PluginMetadataCache(),
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	if xdg.RuntimeDir != "" {
		if err := os.MkdirAll(xdg.RuntimeDir, 0o700); err != nil {
			return err
		}
	}
	return nil
}
