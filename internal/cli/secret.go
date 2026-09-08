package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/errs"
)

// newSecretCmd creates the `envee secret` parent command.
func newSecretCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "secret",
		Short: "Manage secrets in the local env store (used by envee-plugin-env)",
	}

	setCmd := &cobra.Command{
		Use:   "set KEY=VALUE",
		Short: "Set a secret in the local env store",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return secretSet(args[0])
		},
	}

	unsetCmd := &cobra.Command{
		Use:   "unset KEY",
		Short: "Remove a secret from the local env store",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return secretUnset(args[0])
		},
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List all secrets in the local env store",
		RunE: func(cmd *cobra.Command, args []string) error {
			return secretList(cmd.OutOrStdout())
		},
	}

	getCmd := &cobra.Command{
		Use:   "get KEY",
		Short: "Print the value of a secret",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return secretGet(cmd.OutOrStdout(), args[0])
		},
	}

	cmd.AddCommand(setCmd, unsetCmd, listCmd, getCmd)
	return cmd
}

func secretStorePath() (string, error) {
	dir := os.Getenv("XDG_DATA_HOME")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(dir, "envee", "secrets", "env.json"), nil
}

func loadSecrets() (map[string]string, error) {
	path, err := secretStorePath()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]string{}, nil
		}
		return nil, err
	}
	m := map[string]string{}
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	return m, nil
}

func saveSecrets(m map[string]string) error {
	path, err := secretStorePath()
	if err != nil {
		return err
	}
	if mkErr := os.MkdirAll(filepath.Dir(path), 0o700); mkErr != nil {
		return mkErr
	}
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	// Atomic write: temp file + rename.
	tmp, err := os.CreateTemp(filepath.Dir(path), "env-*.json.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	// If we don't reach the successful rename, remove the temp file.
	// Close errors here are best-effort cleanup.
	defer func() {
		_ = os.Remove(tmpPath)
	}()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

func secretSet(arg string) error {
	idx := strings.IndexByte(arg, '=')
	if idx <= 0 {
		return errs.New("E003", "expected KEY=VALUE format").
			WithContext("arg", arg)
	}
	key, value := arg[:idx], arg[idx+1:]
	m, err := loadSecrets()
	if err != nil {
		return err
	}
	m[key] = value
	if err := saveSecrets(m); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "[envee] set %s\n", key)
	return nil
}

func secretUnset(key string) error {
	m, err := loadSecrets()
	if err != nil {
		return err
	}
	if _, ok := m[key]; !ok {
		return errs.New("E012", "secret not found").WithContext("key", key)
	}
	delete(m, key)
	if err := saveSecrets(m); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "[envee] unset %s\n", key)
	return nil
}

func secretList(w io.Writer) error {
	m, err := loadSecrets()
	if err != nil {
		return err
	}
	if len(m) == 0 {
		fmt.Fprintln(w, "(no secrets)")
		return nil
	}
	for k := range m {
		fmt.Fprintf(w, "%s=***REDACTED***\n", k)
	}
	return nil
}

func secretGet(w io.Writer, key string) error {
	m, err := loadSecrets()
	if err != nil {
		return err
	}
	v, ok := m[key]
	if !ok {
		return errs.New("E012", "secret not found").WithContext("key", key)
	}
	fmt.Fprintf(w, "%s=%s\n", key, v)
	return nil
}
