package cli

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/directive"
	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/plugin"
	"github.com/baken667/envee/internal/resolver"
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
  - Daemon status`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runStatus(cmd, jsonOut, showSecrets, profileFlag, trustFlag, pluginsFlag, daemonFlag)
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

func runStatus(cmd *cobra.Command, jsonOut, showSecrets, profileFlag, trustFlag, pluginsFlag, daemonFlag bool) error {
	cwd, err := os.Getwd()
	if err != nil {
		return errs.Wrap(err, "E012", "cannot determine cwd")
	}

	res, err := resolver.New(cwd)
	if err != nil {
		return err
	}
	profile, _ := cmd.Flags().GetString("profile")
	if profile == "" {
		profile = os.Getenv("ENVEE_PROFILE")
	}
	res.SetProfile(profile)

	// Discover (without loading) to show the file hierarchy.
	files, _ := res.Discover()
	cfg, _ := res.LoadAll()

	fmt.Println("envee status")
	fmt.Println("============")
	fmt.Println()
	fmt.Printf("Working dir: %s\n", cwd)
	if cfg != nil {
		fmt.Printf("Active profile: %s (from %s)\n", profile, profileSource(profile, cmd))
		fmt.Printf("Config root:   %s\n", filepath.Dir(cfg.Path))
		fmt.Printf("Config hash:   %s\n", cfg.FileHash)
	}

	fmt.Println()
	fmt.Println("Resolved config files (priority high → low):")
	for i, f := range files {
		fmt.Printf("  %d. %s\n", i+1, f)
	}
	if cfg == nil && len(files) == 0 {
		fmt.Println("  (none found)")
	}

	if cfg != nil {
		fmt.Println()
		fmt.Println("Directives:")
		fmt.Printf("  _.file:     %d entries\n", len(cfg.Directives.File))
		fmt.Printf("  _.path:     %d entries\n", len(cfg.Directives.Path))
		fmt.Printf("  _.script:   %d entries\n", len(cfg.Directives.Script))
		fmt.Printf("  _.secret:   %d entries\n", len(cfg.Directives.Secret))

		// Apply directives for a sample preview.
		osEnv := envToMap(os.Environ())
		dispatcher, _ := plugin.DiscoverAndLoad(cmd.Context())
		result, err := directive.Apply(cmd.Context(), cfg, directive.ApplyOptions{
			ConfigRoot: filepath.Dir(cfg.Path),
			Profile:    profile,
			Cwd:        cwd,
			OSEnv:      osEnv,
		}, dispatcher)
		if err == nil {
			fmt.Println()
			fmt.Printf("Resolved env: %d variables\n", result.Env.Len())
			for _, k := range result.Env.Keys() {
				v, _ := result.Env.Get(k)
				meta, _ := result.Env.GetWithMeta(k)
				if meta.Redacted {
					fmt.Printf("  %s = ***REDACTED*** (source: %s)\n", k, meta.Source)
				} else {
					fmt.Printf("  %s = %s (source: %s)\n", k, v, meta.Source)
				}
			}
		}
	}
	return nil
}

func profileSource(profile string, cmd *cobra.Command) string {
	if v, _ := cmd.Flags().GetString("profile"); v != "" {
		return "--profile flag"
	}
	if env := os.Getenv("ENVEE_PROFILE"); env != "" {
		return "$ENVEE_PROFILE"
	}
	return "config default"
}
