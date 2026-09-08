//go:build windows

package daemon

import "os"

// flockExclusive on Windows: best-effort using LockFileEx.
// Implementation deferred to Phase 3 (Windows tier 3).
func flockExclusive(f *os.File) error {
	// Windows tier 3: not implemented in MVP. Fall back to "no-op".
	return nil
}

// flockUnlock on Windows: no-op.
//
// Returns nothing because this is only called from a cleanup path
// where there is nothing actionable for the caller.
func flockUnlock(f *os.File) {
	_ = f // suppress unused parameter
}
