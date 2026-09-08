// Command envee is the main CLI entry point.
//
// It loads the envee configuration from the current directory (and parents),
// resolves the env, and emits shell-specific export/unset commands.
package main

import (
	"fmt"
	"os"

	"github.com/baken667/envee/internal/cli"
	"github.com/baken667/envee/internal/version"
)

func main() {
	// Set version info on the root command.
	cli.RootCmd.Version = fmt.Sprintf("%s (commit %s, built %s, %s)",
		version.Version, version.Commit, version.Date, version.GoVersion)

	if err := cli.RootCmd.Execute(); err != nil {
		// Cobra already printed the error. We just exit.
		os.Exit(cli.ExitCode(err))
	}
}
