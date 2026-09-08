package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/config"
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

	var listJSON bool
	list := &cobra.Command{
		Use:   "list",
		Short: "List discovered plugins",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runPluginList(cmd, listJSON)
		},
	}
	list.Flags().BoolVar(&listJSON, "json", false, "machine-readable JSON output")

	var infoJSON bool
	info := &cobra.Command{
		Use:   "info <name>",
		Short: "Show plugin metadata",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runPluginInfo(cmd, args[0], infoJSON)
		},
	}
	info.Flags().BoolVar(&infoJSON, "json", false, "machine-readable JSON output")

	install := &cobra.Command{
		Use:    "install <name>",
		Short:  "Install a plugin (via brew or go install)",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return notImplemented("envee plugin install",
				"Install plugins with your package manager, e.g. `go install github.com/baken667/envee/plugins/env@latest`.")
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

	var statusJSON bool
	status := &cobra.Command{
		Use:   "status",
		Short: "Check if the daemon is running",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runDaemonStatus(cmd, statusJSON)
		},
	}
	status.Flags().BoolVar(&statusJSON, "json", false, "machine-readable JSON output")

	start := &cobra.Command{
		Use:    "start",
		Short:  "Start the daemon in the background",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return notImplemented("envee daemon start",
				"Run the daemon directly for now: `enveed &`.")
		},
	}

	stop := &cobra.Command{
		Use:    "stop",
		Short:  "Stop the daemon",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return notImplemented("envee daemon stop",
				"Stop it with your process manager, or `pkill enveed`.")
		},
	}

	cmd.AddCommand(status, start, stop)
	return cmd
}

// newTelemetryCmd creates the `envee telemetry` parent command.
//
// Telemetry does not exist. The subcommands used to print "telemetry
// enabled" / "telemetry disabled", which claimed a state change that never
// happened. The whole tree is hidden until there is something to toggle.
func newTelemetryCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:    "telemetry",
		Short:  "Manage opt-in telemetry (not implemented)",
		Hidden: true,
		Long: `envee collects no telemetry. This command is a placeholder for a
future opt-in mechanism; nothing is sent anywhere today.`,
	}

	notImpl := func(use, short string) *cobra.Command {
		return &cobra.Command{
			Use:   use,
			Short: short,
			RunE: func(cmd *cobra.Command, args []string) error {
				return notImplemented("envee telemetry "+use,
					"envee collects no telemetry; there is nothing to configure.")
			},
		}
	}

	status := &cobra.Command{
		Use:   "status",
		Short: "Show current telemetry setting",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("telemetry: off (envee collects no telemetry)")
			return nil
		},
	}

	cmd.AddCommand(status, notImpl("enable", "Enable telemetry (opt-in)"), notImpl("disable", "Disable telemetry"))
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

Not implemented: there is only one schema version (` + config.SchemaVersion + `),
so there is nothing to migrate from yet.`,
		Hidden: true,
		Args:   cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			_ = fromVersion
			_ = toVersion
			_ = dryRun
			_ = backup
			return notImplemented("envee upgrade",
				"Only schema "+config.SchemaVersion+" exists, so no migration is possible yet.")
		},
	}
	cmd.Flags().StringVar(&fromVersion, "from", "", "explicit source version")
	cmd.Flags().StringVar(&toVersion, "to", "", "explicit target version (default: current)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "show changes, don't apply")
	cmd.Flags().BoolVar(&backup, "backup", true, "create .backup file before writing")
	return cmd
}
