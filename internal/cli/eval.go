package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

// newResolveCmd creates the `envee resolve` command.
func newResolveCmd() *cobra.Command {
	var jsonOut bool
	var shellName string
	var includeOS bool
	var dryRun bool
	cmd := &cobra.Command{
		Use:   "resolve",
		Short: "Compute and print the resolved environment",
		Long: `Resolve all envee.toml files along the cwd hierarchy, apply directives
(merge dotenv files, resolve secrets, run scripts), and print the resulting
env as KEY=VALUE pairs (default) or JSON.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("resolve command not yet implemented in MVP scaffold")
			_ = jsonOut
			_ = shellName
			_ = includeOS
			_ = dryRun
			return nil
		},
	}
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output")
	cmd.Flags().StringVar(&shellName, "shell", "", "shell-escape values for the given shell")
	cmd.Flags().BoolVar(&includeOS, "include-os-env", true, "include OS env vars")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "don't resolve secrets or run scripts")
	return cmd
}

// newEvalCmd creates the `envee eval` command.
func newEvalCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "eval <shell>",
		Short: "Print shell-specific export/unset commands",
		Long: `Output the env diff (vs the current shell) as commands the target shell
can eval. Used by the shell hook on every prompt.

Supports: bash, zsh, fish, nu, pwsh.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("eval command not yet implemented in MVP scaffold")
			return nil
		},
	}
	return cmd
}

// newDiffCmd creates the `envee diff` command.
func newDiffCmd() *cobra.Command {
	var jsonOut bool
	cmd := &cobra.Command{
		Use:   "diff <shell>",
		Short: "Show env changes since last eval",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("diff command not yet implemented in MVP scaffold")
			_ = jsonOut
			return nil
		},
	}
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output")
	return cmd
}

// newExecCmd creates the `envee exec` command.
func newExecCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "exec -- <command> [args...]",
		Short: "Run a command with the loaded env (no shell hook needed)",
		Long: `Spawn a child process with the resolved envee env applied. Useful for:
  - One-off commands without modifying the current shell
  - CI runners
  - IDE integrations
  - Tasks like ` + "`envee exec -- npm test`" + `

Use -- to separate envee flags from the child command:
  envee exec --profile=prod -- kubectl apply -f manifest.yaml`,
		DisableFlagParsing: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("exec command not yet implemented in MVP scaffold")
			return nil
		},
	}
	return cmd
}
