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
		Path:      path,
		Env:       make(map[string]any),
		Profiles:  make(map[string]*Profile),
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

	// Compute canonical hash.
	cfg.FileHash = canonicalHash(data)

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
