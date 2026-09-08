package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/directive"
	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/resolver"
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
			return runResolve(cmd, jsonOut, shellName, includeOS, dryRun)
		},
	}
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output")
	cmd.Flags().StringVar(&shellName, "shell", "", "shell-escape values for the given shell")
	cmd.Flags().BoolVar(&includeOS, "include-os-env", true, "include OS env vars (for context)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "don't resolve secrets or scripts (MVP: same as default)")
	return cmd
}

func runResolve(cmd *cobra.Command, jsonOut bool, shellName string, includeOS, dryRun bool) error {
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

	cfg, err := res.LoadAll()
	if err != nil {
		return err
	}

	// Trust gate — directive.Apply below can run secret plugins and other
	// side-effecting directives, so it must not touch an unapproved config.
	if trustErr := ensureTrusted(cfg); trustErr != nil {
		return trustErr
	}

	osEnv := envToMap(os.Environ())
	dispatcher := dispatcherFor(cmd.Context(), cfg)
	result, err := directive.Apply(cmd.Context(), cfg, directive.ApplyOptions{
		ConfigRoot: filepath.Dir(cfg.Path),
		Profile:    profile,
		Cwd:        cwd,
		OSEnv:      osEnv,
	}, dispatcher)
	if err != nil {
		return err
	}

	if jsonOut {
		return printResolveJSON(result, includeOS)
	}
	return printResolveText(result, includeOS)
}

func printResolveText(result *directive.Result, includeOS bool) error {
	for _, k := range result.Env.Keys() {
		v, _ := result.Env.Get(k)
		meta, _ := result.Env.GetWithMeta(k)
		if meta.Redacted {
			fmt.Printf("%s=***REDACTED***\n", k)
		} else {
			fmt.Printf("%s=%s\n", k, v)
		}
	}
	return nil
}

func printResolveJSON(result *directive.Result, includeOS bool) error {
	out := make(map[string]map[string]any)
	for _, k := range result.Env.Keys() {
		v, _ := result.Env.Get(k)
		meta, _ := result.Env.GetWithMeta(k)
		entry := map[string]any{
			"source": meta.Source,
		}
		if meta.Redacted {
			entry["redacted"] = true
			entry["value"] = "***REDACTED***"
		} else {
			entry["value"] = v
		}
		out[k] = entry
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(out)
}
