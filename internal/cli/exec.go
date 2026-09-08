package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/directive"
	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/resolver"
)

// newExecCmd creates the `envee exec` command.
func newExecCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "exec -- <command> [args...]",
		Short: "Run a command with the loaded env (no shell hook needed)",
		Long: `Spawn a child process with the resolved envee env applied. Useful for:
  - One-off commands without modifying the current shell
  - CI runners
  - IDE integrations
  - Tasks like 'envee exec -- npm test'

Use -- to separate envee flags from the child command:
  envee exec --profile=prod -- kubectl apply -f manifest.yaml`,
		DisableFlagParsing: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runExec(cmd, args)
		},
	}
	return cmd
}

func runExec(cmd *cobra.Command, args []string) error {
	// Find the "--" separator.
	dashIdx := -1
	for i, a := range args {
		if a == "--" {
			dashIdx = i
			break
		}
	}
	if dashIdx < 0 || dashIdx == len(args)-1 {
		return errs.New("E003", "missing command").
			WithHint("Usage: envee exec -- <command> [args...]")
	}
	childArgs := args[dashIdx+1:]
	// Parse envee flags from args[0:dashIdx] (manual since DisableFlagParsing).
	profile := os.Getenv("ENVEE_PROFILE")
	for i := 0; i < dashIdx; i++ {
		if args[i] == "--profile" && i+1 < dashIdx {
			profile = args[i+1]
			i++
		}
	}

	cwd, err := os.Getwd()
	if err != nil {
		return errs.Wrap(err, "E012", "cannot determine cwd")
	}

	res, err := resolver.New(cwd)
	if err != nil {
		return err
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

	// Build child env: start with OS env, then overlay resolved.
	childEnv := os.Environ()
	for _, k := range result.Env.Keys() {
		v, _ := result.Env.Get(k)
		childEnv = append(childEnv, k+"="+v)
	}

	// Find binary in PATH.
	bin, err := exec.LookPath(childArgs[0])
	if err != nil {
		return errs.Wrap(err, "E012", "command not found").
			WithContext("command", childArgs[0])
	}

	c := exec.Command(bin, childArgs[1:]...)
	c.Env = childEnv
	c.Stdin = os.Stdin
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	if err := c.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		return err
	}
	return nil
}

// Unused but reserved.
var _ = fmt.Sprintf
