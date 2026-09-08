package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/config"
	"github.com/baken667/envee/internal/directive"
	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/paths"
	"github.com/baken667/envee/internal/plugin"
	"github.com/baken667/envee/internal/resolver"
	"github.com/baken667/envee/internal/trust"
)

// newStatusCmd creates the `envee status` command.
func newStatusCmd() *cobra.Command {
	var jsonOut bool
	var showSecrets bool
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
			return runStatus(cmd, statusOptions{
				JSON:        jsonOut,
				ShowSecrets: showSecrets,
				Trust:       trustFlag,
				Plugins:     pluginsFlag,
				Daemon:      daemonFlag,
			})
		},
	}
	cmd.Flags().BoolVar(&jsonOut, "json", false, "machine-readable JSON output")
	cmd.Flags().BoolVar(&showSecrets, "show-secrets", false, "reveal redacted values")
	// NOTE: no local --profile flag. There is a persistent --profile string on
	// the root command; declaring a local bool of the same name shadowed it,
	// so `envee status --profile dev` set a bool nothing read while the
	// GetString("profile") call below always came back empty.
	cmd.Flags().BoolVar(&trustFlag, "trust", false, "show trust store contents")
	cmd.Flags().BoolVar(&pluginsFlag, "plugins", false, "show discovered plugins")
	cmd.Flags().BoolVar(&daemonFlag, "daemon", false, "show daemon status")
	return cmd
}

// statusOptions carries the `envee status` flags. Every one of these was
// previously accepted and then ignored.
type statusOptions struct {
	JSON        bool
	ShowSecrets bool
	Trust       bool
	Plugins     bool
	Daemon      bool
}

// statusJSON is the --json payload.
type statusJSON struct {
	Cwd        string             `json:"cwd"`
	Profile    string             `json:"profile,omitempty"`
	ConfigRoot string             `json:"config_root,omitempty"`
	Files      []string           `json:"files"`
	Untrusted  []string           `json:"untrusted"`
	Env        map[string]string  `json:"env,omitempty"`
	Redacted   []string           `json:"redacted,omitempty"`
	TrustStore []trust.Entry      `json:"trust_store,omitempty"`
	Plugins    []discoveredPlugin `json:"plugins,omitempty"`
	Daemon     *daemonState       `json:"daemon,omitempty"`
}

func runStatus(cmd *cobra.Command, opts statusOptions) error {
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

	files, _ := res.Discover()
	cfg, _ := res.LoadAll()

	// Fall back to the config's default profile, the same precedence eval
	// uses (flag > $ENVEE_PROFILE > config default). Without this, status
	// rendered {{profile}} templates as empty and disagreed with eval.
	if profile == "" && cfg != nil {
		profile = cfg.Profile
		res.SetProfile(profile)
	}

	out := statusJSON{Cwd: cwd, Profile: profile, Files: files, Untrusted: []string{}}
	if cfg != nil {
		out.ConfigRoot = filepath.Dir(cfg.Path)
		for _, src := range untrustedSources(cfg) {
			out.Untrusted = append(out.Untrusted, src.Path)
		}
	}

	// Resolving env runs directives, which can spawn secret plugins. Only do
	// that once every contributing file is trusted.
	var result *directive.Result
	if cfg != nil && len(out.Untrusted) == 0 {
		dispatcher, _ := plugin.DiscoverAndLoad(cmd.Context())
		result, _ = directive.Apply(cmd.Context(), cfg, directive.ApplyOptions{
			ConfigRoot: filepath.Dir(cfg.Path),
			Profile:    profile,
			Cwd:        cwd,
			OSEnv:      envToMap(os.Environ()),
		}, dispatcher)
	}
	if result != nil {
		out.Env = make(map[string]string, result.Env.Len())
		for _, k := range result.Env.Keys() {
			v, _ := result.Env.Get(k)
			meta, _ := result.Env.GetWithMeta(k)
			if meta.Redacted {
				out.Redacted = append(out.Redacted, k)
				if !opts.ShowSecrets {
					v = redactedPlaceholder
				}
			}
			out.Env[k] = v
		}
	}

	if opts.Trust {
		entries, err := trust.NewStore().List()
		if err != nil {
			return err
		}
		out.TrustStore = entries
	}
	if opts.Plugins {
		out.Plugins = discoverPlugins(cmd)
	}
	if opts.Daemon {
		st := probeDaemon()
		out.Daemon = &st
	}

	if opts.JSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(out)
	}

	return printStatus(cmd, cfg, result, out, opts, profile)
}

const redactedPlaceholder = "***REDACTED***"

func printStatus(cmd *cobra.Command, cfg *config.Config, result *directive.Result, out statusJSON, opts statusOptions, profile string) error {
	fmt.Println("envee status")
	fmt.Println("============")
	fmt.Println()
	fmt.Printf("Working dir: %s\n", out.Cwd)
	if cfg != nil {
		fmt.Printf("Active profile: %s (from %s)\n", profile, profileSource(profile, cmd))
		fmt.Printf("Config root:   %s\n", out.ConfigRoot)
		fmt.Printf("Config hash:   %s\n", cfg.FileHash)
	}

	fmt.Println()
	fmt.Println("Resolved config files (priority high → low):")
	for i, f := range out.Files {
		fmt.Printf("  %d. %s\n", i+1, f)
	}
	if len(out.Files) == 0 {
		fmt.Println("  (none found)")
	}

	if cfg != nil {
		fmt.Println()
		fmt.Println("Directives:")
		fmt.Printf("  _.file:     %d entries\n", len(cfg.Directives.File))
		fmt.Printf("  _.path:     %d entries\n", len(cfg.Directives.Path))
		fmt.Printf("  _.script:   %d entries\n", len(cfg.Directives.Script))
		fmt.Printf("  _.secret:   %d entries\n", len(cfg.SecretRefs()))
	}

	if len(out.Untrusted) > 0 {
		fmt.Println()
		fmt.Println("Not trusted (env not resolved — run `envee trust`):")
		for _, p := range out.Untrusted {
			fmt.Printf("  %s\n", p)
		}
	} else if result != nil {
		fmt.Println()
		fmt.Printf("Resolved env: %d variables\n", result.Env.Len())
		for _, k := range result.Env.Keys() {
			meta, _ := result.Env.GetWithMeta(k)
			fmt.Printf("  %s = %s (source: %s)\n", k, out.Env[k], meta.Source)
		}
		if len(out.Redacted) > 0 && !opts.ShowSecrets {
			fmt.Println()
			fmt.Printf("  %d value(s) hidden; pass --show-secrets to reveal them.\n", len(out.Redacted))
		}
	}

	if opts.Trust {
		fmt.Println()
		fmt.Printf("Trust store (%s): %d entry/entries\n", paths.TrustStore(), len(out.TrustStore))
		for _, e := range out.TrustStore {
			expiry := "never"
			if !e.ExpiresAt.IsZero() {
				expiry = e.ExpiresAt.Format(time.RFC3339)
			}
			fmt.Printf("  %s\n", e.FilePath)
			fmt.Printf("    hash:    %s\n", e.FileHash)
			fmt.Printf("    trusted: %s by %s (envee %s)\n",
				e.TrustedAt.Format(time.RFC3339), e.TrustedBy, e.ToolVersion)
			fmt.Printf("    expires: %s\n", expiry)
		}
	}

	if opts.Plugins {
		fmt.Println()
		fmt.Printf("Plugins: %d discovered\n", len(out.Plugins))
		for _, pl := range out.Plugins {
			if pl.Metadata == nil {
				fmt.Printf("  %-12s %s (handshake failed: %s)\n", pl.Name, pl.Path, pl.Error)
				continue
			}
			fmt.Printf("  %-12s %s (v%s, api %d)\n", pl.Name, pl.Path, pl.Metadata.Version, pl.Metadata.APIVersion)
		}
	}

	if opts.Daemon && out.Daemon != nil {
		fmt.Println()
		if out.Daemon.Running {
			fmt.Printf("Daemon: running at %s\n", out.Daemon.Socket)
		} else {
			fmt.Printf("Daemon: not running (optional)\n")
			if out.Daemon.Detail != "" {
				fmt.Printf("  %s\n", out.Daemon.Detail)
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
