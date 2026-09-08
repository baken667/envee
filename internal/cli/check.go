package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

// newCheckCmd creates the `envee check` command.
func newCheckCmd() *cobra.Command {
	var strict bool
	var jsonOut bool
	cmd := &cobra.Command{
		Use:   "check [path]",
		Short: "Static analysis of envee.toml",
		Long: `Run static analysis on the given file (or the discovered config in cwd)
to catch common issues:
  - Missing required fields
  - References to non-existent files (_.file, _.script)
  - Unknown secret source plugins
  - Circular template dependencies
  - Suspicious patterns (e.g., redact=false on a variable named *_KEY)`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runCheck(cmd, args, strict, jsonOut)
		},
	}
	cmd.Flags().BoolVar(&strict, "strict", false, "treat warnings as errors")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output")
	return cmd
}

// newDoctorCmd creates the `envee doctor` command.
func newDoctorCmd() *cobra.Command {
	var fix bool
	var jsonOut bool
	cmd := &cobra.Command{
		Use:   "doctor",
		Short: "Run health diagnostics",
		Long: `Check that envee is correctly installed and configured:
  - Binary location and version
  - Shell hook installed in shell config
  - Trust store integrity
  - Plugin discovery
  - Daemon status`,
		RunE: func(cmd *cobra.Command, args []string) error {
			if fix {
				return notImplemented("envee doctor --fix",
					"Run `envee doctor` and apply the hints it prints.")
			}
			return runDoctor(cmd, jsonOut)
		},
	}
	cmd.Flags().BoolVar(&fix, "fix", false, "auto-fix safe issues (not implemented)")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "machine-readable JSON output")
	return cmd
}

// newDebugCmd creates the `envee debug` command.
func newDebugCmd() *cobra.Command {
	var output string
	cmd := &cobra.Command{
		Use:   "debug",
		Short: "Collect diagnostic dump for bug reports",
		Long: `Gather a comprehensive diagnostic snapshot (config files, log tail,
environment summary, version info) into a single file. Share this when
filing a bug report.`,
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			_ = output
			return notImplemented("envee debug",
				"Use `envee status`, `envee resolve` and `envee doctor`, or --log-level=debug.")
		},
	}
	cmd.Flags().StringVarP(&output, "output", "o", "", "output file (default: stdout)")
	return cmd
}

// newCompletionCmd creates the `envee completion` command.
func newCompletionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "completion <shell>",
		Short: "Generate shell completion script",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			// Use cobra's built-in completion generator.
			switch args[0] {
			case "bash":
				return cmd.Root().GenBashCompletion(cmd.OutOrStdout())
			case "zsh":
				return cmd.Root().GenZshCompletion(cmd.OutOrStdout())
			case "fish":
				return cmd.Root().GenFishCompletion(cmd.OutOrStdout(), true)
			case "powershell", "pwsh":
				return cmd.Root().GenPowerShellCompletion(cmd.OutOrStdout())
			default:
				return fmt.Errorf("unsupported shell for completion: %s", args[0])
			}
		},
	}
}

// newVersionCmd creates the `envee version` command.
func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Show envee version",
		Run: func(cmd *cobra.Command, args []string) {
			cmd.Println(cmd.Root().Version)
		},
	}
}
