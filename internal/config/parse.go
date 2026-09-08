package config

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"

	"github.com/BurntSushi/toml"
)

// Parse reads an envee.toml file from disk and returns a *Config.
//
// Returns an *errs.Error (E002) on parse failure, with line/column context.
func Parse(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("envee.toml not found at %s", path)
		}
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	return ParseBytes(path, data)
}

// ParseBytes parses the given bytes as an envee.toml config.
//
// The canonical hash (sha256 of re-marshaled bytes) is computed and stored
// in cfg.FileHash. This makes the hash stable to formatting changes.
func ParseBytes(path string, data []byte) (*Config, error) {
	cfg := &Config{
		Path:       path,
		Env:        make(map[string]any),
		Profiles:   make(map[string]*Profile),
		Directives: &Directives{},
	}

	if _, err := toml.Decode(string(data), cfg); err != nil {
		// TODO: extract line/column from BurntSushi error
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}

	// Default schema if missing
	if cfg.Schema == "" {
		cfg.Schema = SchemaVersion
	}

	// Post-process: lift `env._` table into Directives.
	// BurntSushi decodes nested [env._] as cfg.Env["_"]; we want it
	// in cfg.Directives so the rest of the code can reason about it.
	if raw, ok := cfg.Env["_"]; ok {
		if d, ok := raw.(*Directives); ok {
			cfg.Directives = d
		} else if m, ok := raw.(map[string]any); ok {
			cfg.Directives = directivesFromMap(m)
		}
		delete(cfg.Env, "_")
	}

	// Post-process: lift inline keys in [profiles.X] into Profile.Env.
	// Supports both:
	//   [profiles.dev]
	//   var = "value"     # inline (lifted into Env)
	//
	//   [profiles.dev]
	//   [profiles.dev.env]
	//   var = "value"     # nested (already in Env)
	flattenProfileEnv(cfg, data)

	// Lift `watch` out of [env] into WatchedPaths.
	//
	// It is written inside the [env] table (see examples/basic/envee.toml) and
	// isMetaKey keeps it from becoming a variable, but nothing ever read it:
	// WatchedPaths stayed nil, so the documented "reload when these change"
	// behaviour did not exist. The shell hook's fast path needs this list to
	// know when it may skip calling envee at all.
	if raw, ok := cfg.Env["watch"]; ok {
		cfg.WatchedPaths = append(cfg.WatchedPaths, strSliceOf(raw)...)
		delete(cfg.Env, "watch")
	}

	// Compute canonical hash.
	cfg.FileHash = canonicalHash(data)
	cfg.Sources = []SourceFile{{Path: path, Hash: cfg.FileHash}}

	// Stat for mtime.
	if info, err := os.Stat(path); err == nil {
		cfg.ModTime = info.ModTime()
	}

	return cfg, nil
}

// canonicalHash returns the sha256 of the re-marshaled TOML bytes, ensuring
// the hash is stable to formatting changes (whitespace, key order).
//
// We rely on BurntSushi/toml's behavior of producing deterministic key order
// on re-marshal.
func canonicalHash(data []byte) string {
	var v map[string]any
	if _, err := toml.Decode(string(data), &v); err != nil {
		// Fall back to raw bytes hash if we can't re-parse.
		sum := sha256.Sum256(data)
		return "sha256:" + hex.EncodeToString(sum[:])
	}
	canonical, err := toml.Marshal(v)
	if err != nil {
		sum := sha256.Sum256(data)
		return "sha256:" + hex.EncodeToString(sum[:])
	}
	sum := sha256.Sum256(canonical)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// directivesFromMap converts a raw map[string]any (as produced by BurntSushi
// when [env._] appears) into a *Directives. Used in the post-process step.
func directivesFromMap(m map[string]any) *Directives {
	d := &Directives{}

	// file can be: string, []any (of strings or tables), or map[string]any.
	switch v := m["file"].(type) {
	case string:
		d.File = append(d.File, FileRef{Path: v})
	case []any:
		for _, item := range v {
			if mm, ok := item.(map[string]any); ok {
				d.File = append(d.File, FileRef{
					Path:     strOf(mm["path"]),
					Format:   strOf(mm["format"]),
					Required: boolOf(mm["required"]),
					Redact:   boolOf(mm["redact"]),
					Expand:   boolOf(mm["expand"]),
				})
			} else if s, ok := item.(string); ok {
				d.File = append(d.File, FileRef{Path: s})
			}
		}
	case map[string]any:
		d.File = append(d.File, FileRef{
			Path:     strOf(v["path"]),
			Format:   strOf(v["format"]),
			Required: boolOf(v["required"]),
			Redact:   boolOf(v["redact"]),
			Expand:   boolOf(v["expand"]),
		})
	}

	// path can be: string, []any (of strings or tables).
	switch v := m["path"].(type) {
	case string:
		d.Path = append(d.Path, PathEntry{Path: v})
	case []any:
		for _, item := range v {
			if mm, ok := item.(map[string]any); ok {
				d.Path = append(d.Path, PathEntry{
					Path:     strOf(mm["path"]),
					Position: strOf(mm["position"]),
				})
			} else if s, ok := item.(string); ok {
				d.Path = append(d.Path, PathEntry{Path: s})
			}
		}
	}

	// script: []any of tables.
	if v, ok := m["script"].([]any); ok {
		for _, item := range v {
			if mm, ok := item.(map[string]any); ok {
				d.Script = append(d.Script, ScriptRef{
					Path:        strOf(mm["path"]),
					AllowEnv:    strSliceOf(mm["allow_env"]),
					AllowRead:   strSliceOf(mm["allow_read"]),
					QuotaCPU:    strOf(mm["quota_cpu"]),
					QuotaMemory: strOf(mm["quota_memory"]),
				})
			}
		}
	}

	// secret: a table keyed by variable name.
	//
	//   [env._.secret.DB_PASSWORD]
	//   source = "vault"
	//   ref = "secret/data/db#password"
	//
	// This was previously not handled at all, so the form documented in
	// ADR-0004 and used in the examples was silently discarded: the variable
	// simply never appeared, `envee status` reported "_.secret: 0 entries",
	// and `envee check` said "no problems found" because it had nothing to
	// look at. The shorthand form (NAME = { source = ... } under [env]) was
	// unaffected, which is why this went unnoticed.
	if v, ok := m["secret"].(map[string]any); ok {
		for name, raw := range v {
			mm, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			if d.Secret == nil {
				d.Secret = make(map[string]SecretRef)
			}
			d.Secret[name] = SecretRef{
				Source:   strOf(mm["source"]),
				Ref:      strOf(mm["ref"]),
				Account:  strOf(mm["account"]),
				Vault:    strOf(mm["vault"]),
				Profile:  strOf(mm["profile"]),
				Redact:   boolOf(mm["redact"]),
				Required: boolOf(mm["required"]),
			}
		}
	}

	// source: a list of tables, or a bare string path.
	switch v := m["source"].(type) {
	case string:
		d.Source = append(d.Source, SourceRef{Path: v})
	case []any:
		for _, item := range v {
			switch mm := item.(type) {
			case map[string]any:
				d.Source = append(d.Source, SourceRef{
					Path:   strOf(mm["path"]),
					Shell:  strOf(mm["shell"]),
					Redact: boolOf(mm["redact"]),
				})
			case string:
				d.Source = append(d.Source, SourceRef{Path: mm})
			}
		}
	}

	return d
}

// flattenProfileEnv lifts inline keys in [profiles.X] into Profile.Env.
//
// We re-parse the original data as a map to find inline keys, since
// BurntSushi has already decoded them into Profile fields. Any key that
// is NOT in {extends, required, env, env._} is moved into Profile.Env.
func flattenProfileEnv(cfg *Config, data []byte) {
	var raw map[string]any
	if _, err := toml.Decode(string(data), &raw); err != nil {
		return
	}
	profilesRaw, ok := raw["profiles"].(map[string]any)
	if !ok {
		return
	}
	reservedKeys := map[string]bool{
		"extends": true, "required": true, "env": true, "env._": true,
	}
	for name, raw := range profilesRaw {
		pmap, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		prof, ok := cfg.Profiles[name]
		if !ok || prof == nil {
			continue
		}
		if prof.Env == nil {
			prof.Env = make(map[string]any)
		}
		// Find inline env vars (keys not in reserved set).
		for k, v := range pmap {
			if !reservedKeys[k] {
				prof.Env[k] = v
			}
		}
	}
}

func strOf(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func boolOf(v any) bool {
	if b, ok := v.(bool); ok {
		return b
	}
	return false
}

func strSliceOf(v any) []string {
	// A single value is accepted where a list is expected, matching how the
	// file and path directives already behave.
	if s, ok := v.(string); ok {
		return []string{s}
	}
	if ss, ok := v.([]any); ok {
		out := make([]string, 0, len(ss))
		for _, item := range ss {
			if s, ok := item.(string); ok {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}
