package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

// newPluginCmd creates the `envee plugin` parent command.
func newPluginCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "plugin",
		Short: "Manage plugins",
		Long: `Inspect, install, and test secret/tool provider plugins.

Plugins are external executables named envee-plugin-<name> that communicate
with envee via JSON over stdin/stdout (see docs/adr/0007-plugin-protocol.md).`,
	}

	list := &cobra.Command{
		Use:   "list",
		Short: "List discovered plugins",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("plugin list not yet implemented")
			return nil
		},
	}

	info := &cobra.Command{
		Use:   "info <name>",
		Short: "Show plugin metadata",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("plugin info not yet implemented")
			return nil
		},
	}

	install := &cobra.Command{
		Use:   "install <name>",
		Short: "Install a plugin (via brew or go install)",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("plugin install not yet implemented")
			return nil
		},
	}

	cmd.AddCommand(list, info, install)
	return cmd
}

// newDaemonCmd creates the `envee daemon` parent command.
func newDaemonCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "daemon",
		Short: "Manage the enveed background daemon",
		Long: `The enveed daemon watches envee.toml files for changes and serves
eval requests over a UNIX socket, reducing shell-hook latency to < 1ms.

The daemon is optional — envee falls back to standalone mode when the
daemon is not running.`,
	}

	status := &cobra.Command{
		Use:   "status",
		Short: "Check if the daemon is running",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("daemon status not yet implemented")
			return nil
		},
	}

	start := &cobra.Command{
		Use:   "start",
		Short: "Start the daemon in the background",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("daemon start not yet implemented")
			return nil
		},
	}

	stop := &cobra.Command{
		Use:   "stop",
		Short: "Stop the daemon",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("daemon stop not yet implemented")
			return nil
		},
	}

	cmd.AddCommand(status, start, stop)
	return cmd
}

// newTelemetryCmd creates the `envee telemetry` parent command.
func newTelemetryCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "telemetry",
		Short: "Manage opt-in telemetry",
		Long: `envee can collect anonymous usage events to help prioritize development.
This is OFF by default. Not implemented yet; nothing is collected.`,
	}

	status := &cobra.Command{
		Use:   "status",
		Short: "Show current telemetry setting",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("telemetry: off (default)")
			return nil
		},
	}

	enable := &cobra.Command{
		Use:   "enable",
		Short: "Enable telemetry (opt-in)",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("telemetry enabled (set ENVEE_TELEMETRY=1 in your shell rc)")
			return nil
		},
	}

	disable := &cobra.Command{
		Use:   "disable",
		Short: "Disable telemetry",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("telemetry disabled")
			return nil
		},
	}

	cmd.AddCommand(status, enable, disable)
	return cmd
}

// newUpgradeCmd creates the `envee upgrade` command.
func newUpgradeCmd() *cobra.Command {
	var fromVersion string
	var toVersion string
	var dryRun bool
	var backup bool
	cmd := &cobra.Command{
		Use:   "upgrade",
		Short: "Upgrade envee.toml schema to the current version",
		Long: `Migrate an envee.toml file from an older schema to the current one.
Creates a .backup file by default.`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("upgrade not yet implemented in MVP scaffold")
			_ = fromVersion
			_ = toVersion
			_ = dryRun
			_ = backup
			return nil
		},
	}
	cmd.Flags().StringVar(&fromVersion, "from", "", "explicit source version")
	cmd.Flags().StringVar(&toVersion, "to", "", "explicit target version (default: current)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "show changes, don't apply")
	cmd.Flags().BoolVar(&backup, "backup", true, "create .backup file before writing")
	return cmd
}
