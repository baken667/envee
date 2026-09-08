// Package daemon implements the enveed long-running companion process.
//
// See docs/adr/0008-daemon-protocol.md for the architecture and protocol.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/baken667/envee/internal/paths"
)

// Run starts the daemon and blocks until SIGTERM/SIGINT or an unrecoverable error.
//
// The daemon:
//  1. Acquires a singleton lock at paths.LockFile()
//  2. Binds a UNIX socket at paths.Socket()
//  3. Starts an inotify watcher on $HOME/**/*.envee.toml (Phase 2)
//  4. Serves eval requests until idle timeout or signal
func Run() error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Ensure required directories exist.
	if err := paths.EnsureDirs(); err != nil {
		return fmt.Errorf("ensure dirs: %w", err)
	}

	// Acquire singleton lock.
	lock, err := acquireLock(paths.LockFile())
	if err != nil {
		return fmt.Errorf("acquire lock: %w", err)
	}
	defer releaseLock(lock)

	// Bind UNIX socket.
	listener, err := net.Listen("unix", paths.Socket())
	if err != nil {
		return fmt.Errorf("listen on %s: %w", paths.Socket(), err)
	}
	defer listener.Close()
	defer os.Remove(paths.Socket())

	// Channel for signals.
	sigCh := make(chan os.Signal, 1)
	// signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	fmt.Fprintf(os.Stderr, "enveed: listening on %s\n", paths.Socket())

	// Idle timeout — exit after 30 min of no activity.
	idleTimeout := 30 * time.Minute
	timer := time.NewTimer(idleTimeout)
	defer timer.Stop()

	var wg sync.WaitGroup
	for {
		// Reset idle timer.
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(idleTimeout)

		// Set a deadline so Accept doesn't block forever.
		// If SetDeadline fails (e.g. listener already closed) the next
		// Accept will return an error and the loop will exit cleanly.
		_ = listener.(*net.UnixListener).SetDeadline(time.Now().Add(5 * time.Second))

		conn, err := listener.Accept()
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				select {
				case <-sigCh:
					fmt.Fprintln(os.Stderr, "enveed: signal received, exiting")
					wg.Wait()
					return nil
				case <-ctx.Done():
					return nil
				default:
					continue
				}
			}
			return err
		}

		wg.Add(1)
		go func(c net.Conn) {
			defer wg.Done()
			defer c.Close()
			handleConnection(c)
		}(conn)
	}
}

// handleConnection is a placeholder for the actual eval/resolve protocol.
// Implementation in Phase 2 (see docs/adr/0008).
func handleConnection(_ net.Conn) {
	// TODO: implement msgpack-RPC dispatch
}

// ---- Singleton lock --------------------------------------------------------

type lockFile struct {
	path string
	f    *os.File
}

func acquireLock(path string) (*lockFile, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	// From here on, any error must close f before returning.
	success := false
	defer func() {
		if !success {
			_ = f.Close()
		}
	}()

	// Best-effort exclusive lock; if it fails because another daemon holds it,
	// surface the error.
	if err := flockExclusive(f); err != nil {
		return nil, err
	}
	// Write our PID.
	if _, err := fmt.Fprintf(f, "%d\n", os.Getpid()); err != nil {
		return nil, err
	}
	if err := f.Sync(); err != nil {
		return nil, err
	}
	success = true
	return &lockFile{path: path, f: f}, nil
}

func releaseLock(l *lockFile) {
	if l == nil || l.f == nil {
		return
	}
	flockUnlock(l.f)
	l.f.Close()
	os.Remove(l.path)
}
