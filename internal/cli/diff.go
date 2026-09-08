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
	"github.com/baken667/envee/internal/shell"
)

// newDiffCmd creates the `envee diff` command.
func newDiffCmd() *cobra.Command {
	var jsonOut bool
	cmd := &cobra.Command{
		Use:   "diff <shell>",
		Short: "Show env changes since last eval",
		Long: `Compute the env diff between the current shell and what ` + "`envee eval`" + `
would emit, without actually applying it. Useful for previewing changes.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runDiff(cmd, args[0], jsonOut)
		},
	}
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output")
	return cmd
}

func runDiff(cmd *cobra.Command, shellName string, jsonOut bool) error {
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

	osEnv := envToMap(os.Environ())
	result, err := directive.Apply(cmd.Context(), cfg, directive.ApplyOptions{
		ConfigRoot: filepath.Dir(cfg.Path),
		Profile:    profile,
		Cwd:        cwd,
		OSEnv:      osEnv,
	}, nil)
	if err != nil {
		return err
	}

	adapter := shell.Detect(shellName)
	if adapter == nil {
		return errs.New("E003", "unsupported shell").
			WithContext("shell", shellName)
	}

	output := renderShellDiff(adapter, result, osEnv)

	if jsonOut {
		return json.NewEncoder(os.Stdout).Encode(map[string]string{
			"shell":   shellName,
			"profile": profile,
			"output":  output,
		})
	}
	fmt.Print(output)
	return nil
}
