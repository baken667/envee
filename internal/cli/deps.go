package cli

import (
	"path/filepath"
	"sort"

	"github.com/baken667/envee/internal/config"
)

// evalDeps returns the absolute paths the resolved environment depends on, so
// the shell hook can decide whether it may skip invoking envee at all.
//
// The list covers four things:
//
//   - every config file that contributed (cfg.Sources), so editing any of them
//     is noticed — the same list the trust gate checks;
//   - files pulled in by `_.file`, since their contents become variables;
//   - paths named by `watch` in the config;
//   - the directories those live in, plus the working directory.
//
// The directories matter for creation and deletion: a file that does not exist
// yet cannot be compared against a timestamp, and one that is removed stops
// existing, but in both cases the containing directory's mtime changes. That
// covers dropping a new envee.toml into the current directory and deleting a
// .env, neither of which a file-only list would notice.
//
// Not covered, deliberately: a config appearing in a PARENT directory that had
// none. Watching every ancestor would mean watching busy directories like the
// home directory, and re-resolving on every unrelated change there. direnv has
// the same boundary; the config is picked up on the next directory change.
func evalDeps(cfg *config.Config, cwd string) []string {
	seen := make(map[string]struct{})
	var out []string

	add := func(p string) {
		if p == "" {
			return
		}
		if !filepath.IsAbs(p) {
			return
		}
		if _, ok := seen[p]; ok {
			return
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}

	// The working directory, so a config created here is noticed.
	add(cwd)

	if cfg == nil {
		return out
	}

	root := filepath.Dir(cfg.Path)
	for _, src := range cfg.Sources {
		add(src.Path)
		add(filepath.Dir(src.Path))
	}

	resolve := func(p string) string {
		if p == "" || filepath.IsAbs(p) {
			return p
		}
		return filepath.Join(root, p)
	}

	if cfg.Directives != nil {
		for _, ref := range cfg.Directives.File {
			add(resolve(ref.Path))
		}
		for _, ref := range cfg.Directives.Source {
			add(resolve(ref.Path))
		}
	}
	for _, w := range cfg.WatchedPaths {
		add(resolve(w))
	}

	// Deterministic order keeps eval output stable, which matters for the
	// golden tests and for diffing what the hook received.
	sort.Strings(out)
	return out
}
