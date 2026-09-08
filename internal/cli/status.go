package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

// newStatusCmd creates the `envee status` command.
func newStatusCmd() *cobra.Command {
	var jsonOut bool
	var showSecrets bool
	var profileFlag bool
	var trustFlag bool
	var pluginsFlag bool
	var daemonFlag bool
	cmd := &cobra.Command{
		Use:   "status",
		Short: "Show current envee state",
		Long: `Display information about the current envee configuration:
  - Resolved config files (in priority order)
  - Trust status of each file
  - Active profile and inheritance chain
  - Discovered plugins
  - Daemon status

Combine with --json for machine-readable output.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("status command not yet implemented in MVP scaffold")
			_ = jsonOut
			_ = showSecrets
			_ = profileFlag
			_ = trustFlag
			_ = pluginsFlag
			_ = daemonFlag
			return nil
		},
	}
	cmd.Flags().BoolVar(&jsonOut, "json", false, "machine-readable JSON output")
	cmd.Flags().BoolVar(&showSecrets, "show-secrets", false, "reveal secret values (requires confirm)")
	cmd.Flags().BoolVar(&profileFlag, "profile", false, "show profile info")
	cmd.Flags().BoolVar(&trustFlag, "trust", false, "show trust store contents")
	cmd.Flags().BoolVar(&pluginsFlag, "plugins", false, "show discovered plugins")
	cmd.Flags().BoolVar(&daemonFlag, "daemon", false, "show daemon status")
	return cmd
}
