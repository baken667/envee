package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/directive"
	"github.com/baken667/envee/internal/env"
	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/log"
	"github.com/baken667/envee/internal/plugin"
	"github.com/baken667/envee/internal/resolver"
	"github.com/baken667/envee/internal/shell"
	"github.com/baken667/envee/internal/trust"
)

// newEvalCmd creates the `envee eval <shell>` command.
func newEvalCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "eval <shell>",
		Short: "Print shell-specific export/unset commands",
		Long: `Output the env diff (vs the current shell) as commands the target shell
can eval. Used by the shell hook on every prompt.

Supports: bash, zsh, fish, nu, pwsh.

Example:
  eval "$(envee eval bash)"`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runEval(cmd, args[0])
		},
	}
	return cmd
}

func runEval(cmd *cobra.Command, shellName string) error {
	quiet, _ := cmd.Flags().GetBool("quiet")
	log.SetQuiet(quiet)

	// 1. Determine cwd and config path.
	cwd, err := os.Getwd()
	if err != nil {
		return errs.Wrap(err, "E012", "cannot determine cwd")
	}

	// 2. Resolve all envee.toml files in the hierarchy.
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

	// 3. Trust gate (skip if ENVEE_BYPASS_TRUST=1, for tests/CI).
	if os.Getenv("ENVEE_BYPASS_TRUST") != "1" {
		store := trust.NewStore()
		if trustErr := store.CheckFile(cfg.Path, cfg.FileHash); trustErr != nil {
			return errs.Trust(cfg.Path, cfg.FileHash).WithCause(trustErr)
		}
	}

	// 4. Determine profile: flag > env > config default.
	activeProfile := profile
	if activeProfile == "" {
		activeProfile = cfg.Profile
	}

	// 5. Determine config root (where the resolved config lives).
	configRoot := filepath.Dir(cfg.Path)

	// 6. Apply directives.
	osEnv := envToMap(os.Environ())
	dispatcher, _ := plugin.DiscoverAndLoad(cmd.Context())
	result, err := directive.Apply(cmd.Context(), cfg, directive.ApplyOptions{
		ConfigRoot: configRoot,
		Profile:    activeProfile,
		Cwd:        cwd,
		OSEnv:      osEnv,
	}, dispatcher)
	if err != nil {
		return err
	}

	// 5. Detect shell adapter.
	adapter := shell.Detect(shellName)
	if adapter == nil {
		return errs.New("E003", "unsupported shell").
			WithContext("shell", shellName).
			WithHint("Supported: bash, zsh, fish, nu, pwsh")
	}

	// 6. Compute diff vs OS env, considering PATH specially.
	shellAdapter := shellAdapter(shellName)
	output := renderShellDiff(shellAdapter, result, osEnv)
	fmt.Print(output)
	return nil
}

// renderShellDiff converts a Result into a sequence of shell commands.
//
// PATH entries are emitted via adapter.SetPath (not as a single PATH export).
func renderShellDiff(adapter shell.Adapter, result *directive.Result, osEnv map[string]string) string {
	// Start with current PATH.
	currentPath := osEnv["PATH"]

	// Prepend new dirs (result.PathPrepend already has templates expanded).
	newPath := directive.PrependToPath(result.PathPrepend, currentPath)

	// Build current env map (for diff).
	currentMap := env.New()
	for k, v := range osEnv {
		currentMap.Set(k, v)
	}

	// Compute diff of env values, but skip PATH (handled separately).
	ops := computeDiff(result.Env, currentMap, newPath)

	// Build shell output.
	var out string
	// PATH first.
	if newPath != currentPath {
		out += adapter.SetPath(filepath.SplitList(newPath))
		if !strings.HasSuffix(out, "\n") {
			out += "\n"
		}
	}
	// Then the rest of the env, sorted by key for determinism.
	for _, op := range ops {
		if op.Key == "PATH" {
			continue
		}
		if op.Set {
			out += adapter.Export(op.Key, adapter.Escape(op.Value))
		} else {
			out += adapter.Unset(op.Key)
		}
		if !strings.HasSuffix(out, "\n") {
			out += "\n"
		}
	}
	return out
}

// shellOp mirrors env.DiffOp but is local to this file.
type shellOp struct {
	Key   string
	Set   bool
	Value string
}

func computeDiff(resolved *env.Map, current *env.Map, newPath string) []shellOp {
	var ops []shellOp

	// Add PATH op with the new value (if changed).
	currentPath, _ := current.Get("PATH")
	if newPath != currentPath {
		ops = append(ops, shellOp{Key: "PATH", Set: true, Value: newPath})
	}

	// Walk resolved env.
	for _, k := range resolved.Keys() {
		if k == "" || k == "PATH" {
			continue
		}
		v, _ := resolved.Get(k)
		// false in TOML = unset (already handled by env.Map if Unset was called).
		if v == "" {
			ops = append(ops, shellOp{Key: k, Set: true, Value: ""})
			continue
		}
		oldV, exists := current.Get(k)
		if !exists {
			ops = append(ops, shellOp{Key: k, Set: true, Value: v})
		} else if oldV != v {
			ops = append(ops, shellOp{Key: k, Set: true, Value: v})
		}
	}
	return ops
}

// envToMap converts os.Environ() into a map.
func envToMap(env []string) map[string]string {
	out := make(map[string]string, len(env))
	for _, kv := range env {
		for i := 0; i < len(kv); i++ {
			if kv[i] == '=' {
				out[kv[:i]] = kv[i+1:]
				break
			}
		}
	}
	return out
}
