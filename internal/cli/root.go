// Package cli implements the envee command-line interface.
//
// The root command is created in NewRootCmd and registered with subcommands
// defined in sibling files of this package.
package cli

import (
	"errors"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/log"
)

// RootCmd is the top-level envee command.
//
// All subcommands are attached in NewRootCmd; this variable is exported so
// tests can inspect and execute it.
var RootCmd *cobra.Command

// ExitCode maps a Cobra error to a process exit code per ADR-0017.
//
//   0 — success
//   2 — invalid usage (cobra built-in)
//   3 — trust required
//   4 — config error
//   5 — plugin error
//   6 — internal error
func ExitCode(err error) int {
	if err == nil {
		return 0
	}

	var e *errs.Error
	if errors.As(err, &e) {
		switch e.Code {
		case "E001", "E010":
			return 3 // trust
		case "E002", "E003", "E007", "E008", "E012":
			return 4 // config
		case "E004", "E009", "E015":
			return 5 // plugin/network
		case "E011":
			return 5 // daemon
		}
	}

	// Cobra usage errors are *cobra.Command.SilenceUsage doesn't help; we just
	// treat any error with "unknown command" prefix as usage error (2).
	if strings.Contains(err.Error(), "unknown command") {
		return 2
	}

	return 1
}

func init() {
	RootCmd = NewRootCmd()
}

// NewRootCmd builds the root envee command.
func NewRootCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "envee",
		Short: "Per-directory environment variable manager",
		Long: `envee loads environment variables from envee.toml when you enter a directory.

It is a fast, secure, declarative replacement for direnv. Unlike direnv,
envee uses a structured TOML configuration (no shell scripts in your .envrc)
and supports profiles, secret plugins, and an opt-in WASM script layer.

Get started:
  envee init bash >> ~/.bashrc   # add the shell hook
  cd ~/work/myproj               # enter a project with envee.toml
  envee trust                    # approve the project once
  echo $DATABASE_URL             # env vars are now loaded`,
		SilenceUsage:  true,
		SilenceErrors: false,
		PersistentPreRunE: func(cmd *cobra.Command, _ []string) error {
			return configureLogging(cmd)
		},
	}

	// Persistent flags (available to all subcommands).
	pf := cmd.PersistentFlags()
	pf.String("config", "", "path to envee.toml (default: auto-discover)")
	pf.String("profile", "", "profile to use (overrides $ENVEE_PROFILE)")
	pf.String("log-level", "warn", "log level: trace|debug|info|warn|error")
	pf.String("log-format", "text", "log format: text|json")
	pf.String("color", "auto", "color mode: auto|always|never")
	pf.BoolP("quiet", "q", false, "suppress non-essential output")
	pf.BoolP("verbose", "v", false, "increase log verbosity (-v = info, -vv = debug)")
	pf.Bool("debug", false, "enable debug mode (stacktraces, more logs)")
	pf.Bool("no-telemetry", false, "disable telemetry for this invocation")

	// Register subcommands.
	cmd.AddCommand(
		newInitCmd(),
		newTrustCmd(),
		newDenyCmd(),
		newStatusCmd(),
		newResolveCmd(),
		newEvalCmd(),
		newDiffCmd(),
		newExecCmd(),
		newCheckCmd(),
		newDoctorCmd(),
		newDebugCmd(),
		newCompletionCmd(),
		newVersionCmd(),
		newSecretCmd(),
		newPluginCmd(),
		newDaemonCmd(),
		newTelemetryCmd(),
		newUpgradeCmd(),
	)

	return cmd
}

// configureLogging reads the persistent log flags and applies them to the
// package-level logger before the subcommand body runs.
func configureLogging(cmd *cobra.Command) error {
	level, _ := cmd.Flags().GetString("log-level")
	format, _ := cmd.Flags().GetString("log-format")
	quiet, _ := cmd.Flags().GetBool("quiet")
	verbose, _ := cmd.Flags().GetInt("verbose")
	debug, _ := cmd.Flags().GetBool("debug")

	if quiet {
		level = "error"
	}
	if verbose > 0 {
		switch verbose {
		case 1:
			level = "info"
		case 2:
			level = "debug"
		default:
			level = "trace"
		}
	}
	if debug {
		level = "debug"
	}

	return log.Configure(log.Options{
		Level:  strings.ToLower(level),
		Format: strings.ToLower(format),
	})
}

// errUnknownSubcommand returns a Cobra usage error.
func errUnknownSubcommand(cmd *cobra.Command, name string) error {
	rootName := "envee"
	if cmd.Root() != nil {
		rootName = cmd.Root().Name()
	}
	suggestions := cmd.SuggestionsFor(name)
	if len(suggestions) > 0 {
		return fmt.Errorf("unknown command %q for %q\n\nDid you mean?\n  %s",
			name, rootName, strings.Join(suggestions, "\n  "))
	}
	return fmt.Errorf("unknown command %q for %q", name, rootName)
}
