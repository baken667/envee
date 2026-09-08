// Command gen-docs generates shell completions and man pages from the envee
// cobra command tree.
//
// It exists so the generated artifacts can be shipped in release archives,
// Linux packages and the Homebrew formula without hand-maintaining them.
//
//	go run ./cmd/gen-docs completions --output completions/
//	go run ./cmd/gen-docs man         --output manpages/
//
// With --check the files are generated into a temporary directory and
// compared against --output instead of being written, so CI can prove the
// committed artifacts are current.
package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/spf13/cobra"
	"github.com/spf13/cobra/doc"

	"github.com/baken667/envee/internal/cli"
	"github.com/baken667/envee/internal/version"
)

func main() {
	if err := newRootCmd().Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "gen-docs:", err)
		os.Exit(1)
	}
}

func newRootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:           "gen-docs",
		Short:         "Generate envee completions and man pages",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.AddCommand(newCompletionsCmd(), newManCmd())
	return root
}

// target returns the envee command tree to document. A fresh tree is built
// per invocation so generation never depends on flags parsed elsewhere.
func target() *cobra.Command {
	root := cli.RootCmd
	root.DisableAutoGenTag = true
	return root
}

func newCompletionsCmd() *cobra.Command {
	var output string
	var check bool
	cmd := &cobra.Command{
		Use:   "completions",
		Short: "Generate bash, zsh and fish completions",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			return emit(output, check, generateCompletions)
		},
	}
	cmd.Flags().StringVar(&output, "output", "completions", "directory to write into")
	cmd.Flags().BoolVar(&check, "check", false, "verify --output is up to date instead of writing")
	return cmd
}

func newManCmd() *cobra.Command {
	var output string
	var check bool
	cmd := &cobra.Command{
		Use:   "man",
		Short: "Generate man pages",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			return emit(output, check, generateMan)
		},
	}
	cmd.Flags().StringVar(&output, "output", "manpages", "directory to write into")
	cmd.Flags().BoolVar(&check, "check", false, "verify --output is up to date instead of writing")
	return cmd
}

func generateCompletions(dir string) error {
	root := target()
	type gen struct {
		name string
		fn   func(string) error
	}
	for _, g := range []gen{
		{"envee.bash", func(p string) error { return root.GenBashCompletionFileV2(p, true) }},
		{"envee.zsh", root.GenZshCompletionFile},
		{"envee.fish", func(p string) error { return root.GenFishCompletionFile(p, true) }},
	} {
		if err := g.fn(filepath.Join(dir, g.name)); err != nil {
			return fmt.Errorf("generate %s: %w", g.name, err)
		}
	}
	return nil
}

func generateMan(dir string) error {
	hdr := &doc.GenManHeader{
		Title:   "ENVEE",
		Section: "1",
		Source:  "envee " + version.Version,
		Manual:  "envee Manual",
	}
	return doc.GenManTree(target(), hdr, dir)
}

// emit either writes the artifacts into dir, or (with check) generates them
// into a temporary directory and diffs the two.
func emit(dir string, check bool, generate func(string) error) error {
	if !check {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		return generate(dir)
	}

	tmp, err := os.MkdirTemp("", "envee-gen-docs-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)

	if err := generate(tmp); err != nil {
		return err
	}
	return compareDirs(tmp, dir)
}

func compareDirs(want, got string) error {
	entries, err := os.ReadDir(want)
	if err != nil {
		return err
	}
	var problems []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		wantData, err := os.ReadFile(filepath.Join(want, e.Name()))
		if err != nil {
			return err
		}
		gotData, err := os.ReadFile(filepath.Join(got, e.Name()))
		if os.IsNotExist(err) {
			problems = append(problems, e.Name()+" is missing")
			continue
		}
		if err != nil {
			return err
		}
		if !bytes.Equal(wantData, gotData) {
			problems = append(problems, e.Name()+" is out of date")
		}
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		return fmt.Errorf("generated docs in %s are stale (run `make docs`):\n  %s",
			got, strings.Join(problems, "\n  "))
	}
	return nil
}
