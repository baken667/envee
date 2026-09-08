package cli

import (
	"encoding/json"
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
	var export string
	var verifyFrom string
	var publicKey string
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
			if verifyFrom != "" {
				return runTrustImport(verifyFrom, publicKey)
			}
			if err := runTrust(cmd, args, sign, keyPath, ttl, yes, remove); err != nil {
				return err
			}
			if export != "" {
				return runTrustExport(cmd, args, export)
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&sign, "sign", false, "sign trust entry with ed25519 key")
	cmd.Flags().StringVar(&keyPath, "key", "", "path to signing key (implies --sign)")
	cmd.Flags().StringVar(&ttl, "ttl", "never", "trust TTL (e.g., 24h, 7d, never)")
	cmd.Flags().BoolVar(&yes, "yes", false, "auto-approve without interactive prompt")
	cmd.Flags().BoolVar(&remove, "remove", false, "remove trust entry")
	cmd.Flags().StringVar(&export, "export", "", "write the trust entry to a file so it can be shared")
	cmd.Flags().StringVar(&verifyFrom, "from", "", "import a shared trust entry from a file (requires --public-key)")
	cmd.Flags().StringVar(&publicKey, "public-key", "", "public key to verify an imported entry against")
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
		cfg, parseErr := config.Parse(target)
		if parseErr != nil {
			return parseErr
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

	// Build the entry first, sign it if asked, then store it once. Storing
	// before signing would leave an unsigned entry behind when signing fails.
	entry := store.NewEntry(target, cfg.FileHash, ttl)
	if sign || keyPath != "" {
		if err := signEntry(&entry, keyPath); err != nil {
			return err
		}
	}
	if err := store.Put(entry); err != nil {
		return err
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

// signEntry attaches an ed25519 signature to a trust entry.
//
// A signed entry can be shared: a reviewer signs their approval of a config,
// and colleagues verify it against the reviewer's public key rather than
// reviewing the file again. See docs/adr/0004-trust-model.md.
func signEntry(entry *trust.Entry, keyPath string) error {
	if keyPath == "" {
		keyPath = defaultSigningKey()
		if keyPath == "" {
			return errs.New("E003", "no signing key found").
				WithHint("Pass --key PATH, or create one with: ssh-keygen -t ed25519")
		}
	}

	priv, err := trust.LoadPrivateKey(keyPath)
	if err != nil {
		return errs.Wrap(err, "E013", "cannot use signing key").
			WithContext("key", keyPath)
	}
	if err := trust.SignEntry(entry, priv, time.Now()); err != nil {
		return errs.Wrap(err, "E003", "signing failed")
	}

	fmt.Fprintf(os.Stderr, "         signed:  %s (key %s)\n",
		entry.Signature.Algorithm, entry.Signature.KeyID)
	return nil
}

// defaultSigningKey returns ~/.ssh/id_ed25519 when it exists. Anything else
// is ambiguous enough that the user should name the key explicitly.
func defaultSigningKey() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	candidate := filepath.Join(home, ".ssh", "id_ed25519")
	if _, err := os.Stat(candidate); err != nil {
		return ""
	}
	return candidate
}

// runTrustExport writes the stored trust entry for a config to a file, so an
// approval can be handed to someone else. Only useful together with --sign:
// without a signature the recipient has nothing to check it against.
func runTrustExport(cmd *cobra.Command, args []string, dest string) error {
	target, err := trustTarget(cmd, args)
	if err != nil {
		return err
	}
	cfg, err := config.Parse(target)
	if err != nil {
		return err
	}

	entry, ok, err := trust.NewStore().Get(cfg.FileHash)
	if err != nil {
		return err
	}
	if !ok {
		return errs.New("E001", "nothing to export: this config is not trusted").
			WithContext("path", target)
	}
	if entry.Signature == nil {
		fmt.Fprintln(os.Stderr,
			"[envee] WARN: exporting an unsigned entry — a recipient cannot verify it. "+
				"Re-run with --sign to make it shareable.")
	}

	data, err := json.MarshalIndent(entry, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(dest, append(data, '\n'), 0o644); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "[envee] exported trust entry to %s\n", dest)
	return nil
}

// runTrustImport verifies a shared trust entry against a public key and, only
// if it checks out, adds it to the local store.
//
// The signature is what makes this safe: without verification this would be a
// way to have someone else approve configs on your behalf.
func runTrustImport(from, publicKeyPath string) error {
	if publicKeyPath == "" {
		return errs.New("E003", "--from requires --public-key").
			WithHint("Importing an entry without verifying its signature would let " +
				"anyone approve configs on your behalf.")
	}

	data, err := os.ReadFile(from)
	if err != nil {
		return errs.Wrap(err, "E012", "cannot read the shared trust entry")
	}
	var entry trust.Entry
	if parseErr := json.Unmarshal(data, &entry); parseErr != nil {
		return errs.Wrap(parseErr, "E002", "shared trust entry is not valid JSON").
			WithContext("path", from)
	}

	pub, err := trust.LoadPublicKey(publicKeyPath)
	if err != nil {
		return errs.Wrap(err, "E013", "cannot use public key").
			WithContext("key", publicKeyPath)
	}
	if err := trust.VerifyEntry(entry, pub); err != nil {
		return errs.Wrap(err, "E001", "signature verification failed").
			WithContext("path", from).
			WithHint("The entry was modified, or it was signed by a different key.")
	}

	if err := trust.NewStore().Put(entry); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "[envee] imported verified trust entry\n")
	fmt.Fprintf(os.Stderr, "         path:      %s\n", entry.FilePath)
	fmt.Fprintf(os.Stderr, "         hash:      %s\n", entry.FileHash)
	fmt.Fprintf(os.Stderr, "         signed by: %s (key %s)\n", entry.TrustedBy, entry.Signature.KeyID)
	return nil
}

// trustTarget resolves which config a trust subcommand acts on.
func trustTarget(cmd *cobra.Command, args []string) (string, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", errs.Wrap(err, "E012", "cannot determine cwd")
	}
	if len(args) > 0 {
		if filepath.IsAbs(args[0]) {
			return args[0], nil
		}
		return filepath.Join(cwd, args[0]), nil
	}
	if p, _ := cmd.Flags().GetString("config"); p != "" {
		return p, nil
	}
	return filepath.Join(cwd, "envee.toml"), nil
}
