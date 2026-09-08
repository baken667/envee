//go:build !windows

package daemon

import (
	"os"
	"syscall"
)

// flockExclusive acquires an exclusive advisory lock on f.
// On Unix, this is implemented via flock(2).
func flockExclusive(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
}

// flockUnlock releases the lock on f.
func flockUnlock(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
}
