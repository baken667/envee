package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// newInitCmd creates the `envee init <shell>` command.
func newInitCmd() *cobra.Command {
	var cached bool
	cmd := &cobra.Command{
		Use:   "init <shell>",
		Short: "Generate shell hook code",
		Long: `Output shell-specific hook code to be eval'd at shell startup.

Supported shells: bash, zsh, fish, nu, pwsh.

Add to your shell config:
  bash:  eval "$(envee init bash)"
  zsh:   eval "$(envee init zsh)"
  fish:  envee init fish | source

Or use --cached to write to a file you source (faster startup):
  echo 'eval "$(envee init bash)"' >> ~/.bashrc
`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			selfPath, err := os.Executable()
			if err != nil {
				return err
			}
			shell := shellAdapter(args[0])
			if shell == nil {
				return errUnknownSubcommand(cmd, args[0])
			}
			if cached {
				// Reserved: write to $XDG_CACHE_HOME/envee/init.<shell>
				_ = cached
			}
			fmt.Print(shell.Init(selfPath))
			return nil
		},
	}
	cmd.Flags().BoolVar(&cached, "cached", false, "write to cache file instead of stdout")
	return cmd
}
