package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

// newTrustCmd creates the `envee trust` command.
func newTrustCmd() *cobra.Command {
	var sign bool
	var keyPath string
	var ttl string
	var yes bool
	var remove bool
	var secretsOnly bool
	cmd := &cobra.Command{
		Use:   "trust [path]",
		Short: "Trust envee.toml (review and approve its content)",
		Long: `Approve the envee.toml at the given path (or the current directory).

When you trust a file, envee records a SHA-256 hash of its canonical content
in your trust store. Any subsequent change invalidates the trust and requires
re-approval.

Examples:
  envee trust                       # trust envee.toml in cwd
  envee trust ./configs/dev.toml    # trust a specific file
  envee trust --ttl=24h             # expire after 24 hours
  envee trust --sign --key ~/.ssh/id_ed25519  # sign for team sharing
  envee trust --remove              # revoke trust`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("trust command not yet implemented in MVP scaffold")
			_ = sign
			_ = keyPath
			_ = ttl
			_ = yes
			_ = remove
			_ = secretsOnly
			return nil
		},
	}
	cmd.Flags().BoolVar(&sign, "sign", false, "sign trust entry with ed25519 key")
	cmd.Flags().StringVar(&keyPath, "key", "", "path to signing key (implies --sign)")
	cmd.Flags().StringVar(&ttl, "ttl", "never", "trust TTL (e.g., 24h, 7d, never)")
	cmd.Flags().BoolVar(&yes, "yes", false, "auto-approve without interactive prompt")
	cmd.Flags().BoolVar(&remove, "remove", false, "remove trust entry")
	cmd.Flags().BoolVar(&secretsOnly, "secrets-only", false, "only review secret sources")
	return cmd
}

// newDenyCmd creates the `envee deny` command.
func newDenyCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "deny [path]",
		Short: "Deny envee.toml (explicit block)",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("deny command not yet implemented in MVP scaffold")
			return nil
		},
	}
	return cmd
}
