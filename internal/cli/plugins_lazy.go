package cli

import (
	"context"

	"github.com/baken667/envee/internal/config"
	"github.com/baken667/envee/internal/directive"
	"github.com/baken667/envee/internal/plugin"
)

// dispatcherFor returns a plugin dispatcher only when cfg actually needs one.
//
// plugin.DiscoverAndLoad walks every directory in $PATH and then runs
// `metadata` as a subprocess for each envee-plugin-* it finds. eval runs from
// the shell hook on every prompt, so doing that unconditionally charged the
// PATH walk — measured at ~0.9 ms and 4400 allocations against a normal $PATH
// (see BenchmarkDiscoverPathsRealPATH) — to every prompt, plus a subprocess
// per installed plugin, for configs that declare no secrets at all.
//
// The perverse consequence was that installing plugins made every prompt
// slower whether or not the current project used them.
//
// SecretRefs covers both spellings, [env._.secret.NAME] and the shorthand
// NAME = { source = ... }, so a config using either still gets its plugins.
func dispatcherFor(ctx context.Context, cfg *config.Config) directive.PluginResolver {
	if cfg == nil || len(cfg.SecretRefs()) == 0 {
		return nil
	}
	dispatcher, err := plugin.DiscoverAndLoad(ctx)
	if err != nil {
		// Discovery failing is not fatal here: Apply reports a clear
		// "plugin not found" per secret, which names the source the config
		// asked for and is far more useful than a discovery error.
		return nil
	}
	return dispatcher
}
