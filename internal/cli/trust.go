package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/config"
	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/trust"
)

// newTrustCmd creates the `envee trust` command.
func newTrustCmd() *cobra.Command {
	var sign bool
	var keyPath string
	var ttl string
	var yes bool
	var remove bool
	cmd := &cobra.Command{
		Use:   "trust [path]",
		Short: "Trust envee.toml (review and approve its content)",
		Long: `Approve the envee.toml at the given path (or in the current directory).

When you trust a file, envee records a SHA-256 hash of its canonical content
in your trust store. Any subsequent change invalidates the trust and requires
re-approval.

Examples:
  envee trust                       # trust envee.toml in cwd
  envee trust ./configs/dev.toml    # trust a specific file
  envee trust --ttl=24h             # expire after 24 hours
  envee trust --remove              # revoke trust`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runTrust(cmd, args, sign, keyPath, ttl, yes, remove)
		},
	}
	cmd.Flags().BoolVar(&sign, "sign", false, "sign trust entry with ed25519 key")
	cmd.Flags().StringVar(&keyPath, "key", "", "path to signing key (implies --sign)")
	cmd.Flags().StringVar(&ttl, "ttl", "never", "trust TTL (e.g., 24h, 7d, never)")
	cmd.Flags().BoolVar(&yes, "yes", false, "auto-approve without interactive prompt")
	cmd.Flags().BoolVar(&remove, "remove", false, "remove trust entry")
	return cmd
}

// newDenyCmd creates the `envee deny` command.
func newDenyCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "deny [path]",
		Short: "Deny envee.toml (explicit block)",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runDeny(cmd, args)
		},
	}
	return cmd
}

func runTrust(cmd *cobra.Command, args []string, sign bool, keyPath, ttlStr string, yes, remove bool) error {
	cwd, err := os.Getwd()
	if err != nil {
		return errs.Wrap(err, "E012", "cannot determine cwd")
	}

	// Determine target path.
	var target string
	if len(args) > 0 {
		target = args[0]
		if !filepath.IsAbs(target) {
			target = filepath.Join(cwd, target)
		}
	} else {
		target = filepath.Join(cwd, "envee.toml")
	}

	store := trust.NewStore()

	// Handle --remove.
	if remove {
		// Load the file to get its hash, then revoke.
		cfg, err := config.Parse(target)
		if err != nil {
			return err
		}
		if revErr := store.Revoke(cfg.FileHash); revErr != nil {
			return revErr
		}
		fmt.Fprintf(os.Stderr, "[envee] trust revoked for %s (hash %s)\n", target, cfg.FileHash)
		return nil
	}

	// Parse the config.
	cfg, err := config.Parse(target)
	if err != nil {
		return err
	}

	// Build summary.
	summary := trust.BuildSummary(cfg)
	fmt.Fprint(os.Stderr, summary.String())

	// Interactive prompt.
	if !yes && !sign {
		resp, promptErr := trust.Prompt(trust.PromptOptions{
			Question: "Trust this file? [Y/n/d(iff)/s(kip)/q(uit)] ",
			Default:  trust.ResponseGrant,
			Yes:      false,
		})
		if promptErr != nil {
			return promptErr
		}
		switch resp {
		case trust.ResponseGrant:
			// proceed
		case trust.ResponseDeny, trust.ResponseQuit:
			fmt.Fprintln(os.Stderr, "[envee] trust not granted")
			return nil
		case trust.ResponseShowDiff:
			// Show raw file content (simplified diff for MVP).
			data, _ := os.ReadFile(target)
			fmt.Fprintln(os.Stderr, "--- envee.toml ---")
			fmt.Fprintln(os.Stderr, string(data))
			fmt.Fprintln(os.Stderr, "--- end ---")
			// Re-prompt.
			return runTrust(cmd, args, sign, keyPath, ttlStr, true, false)
		case trust.ResponseSkip:
			fmt.Fprintln(os.Stderr, "[envee] skipped")
			return nil
		}
	}

	// Compute TTL.
	ttl, err := parseTTL(ttlStr)
	if err != nil {
		return err
	}

	// Record trust.
	if err := store.Trust(target, cfg.FileHash, ttl); err != nil {
		return err
	}

	// Optional signing.
	if sign || keyPath != "" {
		if err := signTrustEntry(store, target, cfg, keyPath); err != nil {
			return err
		}
	}

	expStr := "never"
	if ttl > 0 {
		expStr = time.Now().Add(ttl).Format(time.RFC3339)
	}
	fmt.Fprintf(os.Stderr, "[envee] trusted %s\n", target)
	fmt.Fprintf(os.Stderr, "         hash:    %s\n", cfg.FileHash)
	fmt.Fprintf(os.Stderr, "         expires: %s\n", expStr)
	return nil
}

func runDeny(cmd *cobra.Command, args []string) error {
	cwd, err := os.Getwd()
	if err != nil {
		return errs.Wrap(err, "E012", "cannot determine cwd")
	}
	target := filepath.Join(cwd, "envee.toml")
	if len(args) > 0 {
		target = args[0]
	}
	store := trust.NewStore()
	if err := store.Deny(target); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "[envee] denied %s\n", target)
	return nil
}

// parseTTL parses "24h", "7d", "never" → time.Duration.
// "never" → 0 (no expiry).
func parseTTL(s string) (time.Duration, error) {
	if s == "" || s == "never" {
		return 0, nil
	}
	// Try standard duration first.
	if d, err := time.ParseDuration(s); err == nil {
		return d, nil
	}
	// Try days.
	if len(s) > 1 && s[len(s)-1] == 'd' {
		d, err := time.ParseDuration(s[:len(s)-1] + "h")
		if err == nil {
			return d * 24, nil
		}
	}
	return 0, fmt.Errorf("invalid TTL %q (use duration like 24h, 7d, or 'never')", s)
}

// signTrustEntry is a stub. Real ed25519 signing comes in T2.6.
func signTrustEntry(store *trust.Store, target string, cfg *config.Config, keyPath string) error {
	// Placeholder: log that signing is not yet implemented.
	fmt.Fprintln(os.Stderr, "[envee] WARN: --sign not yet implemented (T2.6)")
	return nil
}
