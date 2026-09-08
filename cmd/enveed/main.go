// Command enveed is the long-running daemon companion to envee.
//
// It watches envee.toml files in the user's home directory via inotify/FSEvents,
// keeps parsed configs in memory, and serves eval requests over a UNIX socket.
//
// The daemon is optional — envee falls back to a standalone mode when enveed
// is not running. See docs/adr/0008-daemon-protocol.md.
package main

import (
	"os"

	"github.com/baken667/envee/internal/daemon"
)

func main() {
	if err := daemon.Run(); err != nil {
		os.Stderr.WriteString("enveed: " + err.Error() + "\n")
		os.Exit(1)
	}
}
