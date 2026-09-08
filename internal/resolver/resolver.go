// Package resolver discovers and merges envee.toml files along the
// filesystem hierarchy.
//
// Discovery order (highest to lowest priority):
//  1. envee.local.toml (cwd)        — personal overrides, should be gitignored
//  2. envee.toml (cwd)              — project config
//  3. envee.d/*.toml (cwd)          — fragments, alphabetical
//  4. envee.local.<profile>.toml    — profile-specific personal
//  5. envee.<profile>.toml          — profile-specific
//  6. (parent dirs, recursive until stop_search_up or root)
//  7. ~/.config/envee/config.toml   — global defaults
//
// See docs/adr/0003-naming-files.md.
package resolver

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/baken667/envee/internal/config"
)

// Resolver discovers config files for a given working directory.
type Resolver struct {
	cwd        string
	fsRoot     string
	configDir  string // XDG config home
	profile    string
	stopAtRoot string // optional git root, walk stops here
}

// New creates a Resolver rooted at cwd.
func New(cwd string) (*Resolver, error) {
	abs, err := filepath.Abs(cwd)
	if err != nil {
		return nil, err
	}
	return &Resolver{
		cwd:       abs,
		fsRoot:    string(filepath.Separator),
		configDir: filepath.Join(os.Getenv("XDG_CONFIG_HOME"), "envee"),
	}, nil
}

// SetProfile overrides the active profile.
func (r *Resolver) SetProfile(p string) { r.profile = p }

// SetStopAtRoot configures an upper bound for the upward walk (e.g., git root).
func (r *Resolver) SetStopAtRoot(p string) { r.stopAtRoot = p }

// Discover returns all config file paths in priority order (high to low).
//
// The result does not include files that don't exist on disk.
func (r *Resolver) Discover() ([]string, error) {
	var out []string
	seen := make(map[string]struct{})

	add := func(p string) {
		if _, ok := seen[p]; ok {
			return
		}
		seen[p] = struct{}{}
		if _, err := os.Stat(p); err == nil {
			out = append(out, p)
		}
	}

	// Walk from cwd up to fsRoot (or stopAtRoot).
	for dir := r.cwd; ; dir = filepath.Dir(dir) {
		// Profile-specific files (higher priority than base)
		if r.profile != "" {
			add(filepath.Join(dir, "envee.local."+r.profile+".toml"))
			add(filepath.Join(dir, "envee."+r.profile+".toml"))
		}
		// Base files
		add(filepath.Join(dir, "envee.local.toml"))
		add(filepath.Join(dir, "envee.toml"))
		// Fragments
		if entries, err := os.ReadDir(filepath.Join(dir, "envee.d")); err == nil {
			var tomls []string
			for _, e := range entries {
				if e.IsDir() {
					continue
				}
				name := e.Name()
				if strings.HasSuffix(name, ".toml") && !strings.HasPrefix(name, ".") {
					tomls = append(tomls, filepath.Join(dir, "envee.d", name))
				}
			}
			sort.Strings(tomls)
			for _, p := range tomls {
				add(p)
			}
		}

		// Stop conditions
		if dir == r.fsRoot {
			break
		}
		if r.stopAtRoot != "" && dir == r.stopAtRoot {
			break
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break // safety
		}
		dir = parent
	}

	// Global defaults
	if r.configDir != "" {
		add(filepath.Join(r.configDir, "config.toml"))
	}

	return out, nil
}

// LoadAll discovers, parses, and merges all config files into a single *config.Config.
//
// Merge semantics:
//   - Scalar values: later (higher priority) wins.
//   - Maps (env, profiles, secrets): recursive merge.
//   - Arrays: replace, not concat (so _.path can be overridden).
func (r *Resolver) LoadAll() (*config.Config, error) {
	files, err := r.Discover()
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("no envee.toml found (searched from %s upward)", r.cwd)
	}

	var merged *config.Config
	for _, f := range files {
		cfg, err := config.Parse(f)
		if err != nil {
			return nil, err
		}
		if merged == nil {
			merged = cfg
		} else {
			MergeInto(merged, cfg)
		}
		// Honor stop_search_up from the first config that sets it.
		if cfg.StopSearchUp {
			break
		}
	}
	return merged, nil
}

// MergeInto merges src into dst (dst is mutated, src is unchanged).
func MergeInto(dst, src *config.Config) {
	if src.Profile != "" {
		dst.Profile = src.Profile
	}
	if src.StopSearchUp {
		dst.StopSearchUp = true
	}
	if src.ProfileFromBranch {
		dst.ProfileFromBranch = true
	}
	for k, v := range src.Env {
		dst.Env[k] = v
	}
	for name, prof := range src.Profiles {
		existing, ok := dst.Profiles[name]
		if !ok {
			dst.Profiles[name] = prof
			continue
		}
		// Merge profile.
		existing.Extends = append(existing.Extends, prof.Extends...)
		for k, v := range prof.Env {
			existing.Env[k] = v
		}
		existing.Required = append(existing.Required, prof.Required...)
	}
	if src.Directives != nil {
		mergeDirectives(dst.Directives, src.Directives)
	}
	dst.WatchedPaths = append(dst.WatchedPaths, src.WatchedPaths...)
}

func mergeDirectives(dst, src *config.Directives) {
	dst.File = append(dst.File, src.File...)
	dst.Path = append(dst.Path, src.Path...)
	dst.Script = append(dst.Script, src.Script...)
	dst.Source = append(dst.Source, src.Source...)
	if src.Secret != nil {
		if dst.Secret == nil {
			dst.Secret = make(map[string]config.SecretRef)
		}
		for k, v := range src.Secret {
			dst.Secret[k] = v
		}
	}
}
