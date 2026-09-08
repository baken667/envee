package cli

import (
	"github.com/baken667/envee/internal/config"
	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/trust"
)

// ensureTrusted verifies that EVERY config file that contributed to cfg is
// trusted, not just the first one.
//
// A resolved Config is normally the merge of several files: envee.toml,
// envee.local.toml, envee.d/*.toml, configs from parent directories, and the
// global config. cfg.Path and cfg.FileHash describe only the first of those,
// so checking them alone lets an attacker who can write any of the other
// files (envee.local.toml is gitignored, envee.d/ is a drop-in directory)
// inject env vars and directives that the user never approved.
func ensureTrusted(cfg *config.Config) error {
	sources := cfg.Sources
	if len(sources) == 0 {
		// Defensive: a Config that did not come from config.Parse. Fall back
		// to the single-file identity rather than trusting silently.
		sources = []config.SourceFile{{Path: cfg.Path, Hash: cfg.FileHash}}
	}

	store := trust.NewStore()
	for _, src := range sources {
		if err := store.CheckFile(src.Path, src.Hash); err != nil {
			return errs.Trust(src.Path, src.Hash).WithCause(err)
		}
	}
	return nil
}

// untrustedSources returns the config files in cfg that are not currently
// trusted. Used by diagnostic commands that report trust state instead of
// refusing to run.
func untrustedSources(cfg *config.Config) []config.SourceFile {
	if cfg == nil {
		return nil
	}
	store := trust.NewStore()
	var out []config.SourceFile
	for _, src := range cfg.Sources {
		if !store.IsTrusted(src.Path, src.Hash) {
			out = append(out, src)
		}
	}
	return out
}
