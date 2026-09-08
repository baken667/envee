//go:build windows

package daemon

import "os"

// flockExclusive on Windows: best-effort using LockFileEx.
// Implementation deferred to Phase 3 (Windows tier 3).
func flockExclusive(f *os.File) error {
	// Windows tier 3: not implemented in MVP. Fall back to "no-op".
	return nil
}

func flockUnlock(f *os.File) error {
	return nil
}
