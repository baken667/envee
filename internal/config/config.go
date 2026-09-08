// Package config defines the envee configuration schema and parsing.
//
// A Config represents a single envee.toml file. Multiple Configs are merged
// by the resolver package to form the final env.
//
// Schema is "envee/v1" (per docs/adr/0002-config-format-toml.md).
package config

import (
	"sort"
	"time"
)

// SchemaVersion is the current envee schema version.
const SchemaVersion = "envee/v1"

// Config is the parsed form of a single envee.toml file.
type Config struct {
	// Schema is the pinned schema version (e.g., "envee/v1").
	Schema string `toml:"schema"`

	// Profile is the default profile to activate when $ENVEE_PROFILE is unset.
	Profile string `toml:"profile"`

	// StopSearchUp, when true, prevents parent directories from being searched.
	StopSearchUp bool `toml:"stop_search_up"`

	// ProfileFromBranch, when true, derives the profile from the git branch
	// name (e.g., "feature/prod-debug" -> "prod"). Off by default.
	ProfileFromBranch bool `toml:"profile_from_branch"`

	// Env is the map of variable name to its (possibly structured) value.
	//
	// Values can be:
	//   - string  (literal value, may contain {{...}} templates)
	//   - int64   (TOML integer)
	//   - bool    (TOML boolean; false unsets the variable)
	//   - []any   (array of any of the above; first element must be a string)
	//   - map[string]any  (inline table: { value, required, redact, secret, ... })
	Env map[string]any `toml:"env"`

	// Profiles contains profile-specific overlays (keyed by profile name).
	Profiles map[string]*Profile `toml:"profiles"`

	// ProfilesDotD is the optional list of profile-specific files loaded
	// when their profile is active (e.g., envee.dev.toml, envee.prod.toml).
	// This is populated by the resolver, not by the TOML itself.

	// Directives are top-level directives that don't map to env variables.
	// These are populated from keys under [env._] in TOML.
	Directives *Directives `toml:"env._"`

	// Path is the absolute path to the source file (for error messages).
	Path string `toml:"-"`

	// FileHash is the SHA-256 of the canonical (re-marshaled) file content.
	// Populated by the resolver.
	FileHash string `toml:"-"`

	// ModTime is the file's modification time.
	ModTime time.Time `toml:"-"`

	// WatchedPaths are additional files this config depends on.
	// Populated by the watcher (e.g., dotenv files referenced via _.file).
	WatchedPaths []string `toml:"-"`
}

// Profile is a per-profile overlay of env variables and metadata.
type Profile struct {
	// Extends is the list of other profiles to load before this one
	// (in order, earlier profiles overridden by later ones).
	Extends []string `toml:"extends"`

	// Env contains the profile-specific env variable overrides.
	Env map[string]any `toml:"env"`

	// Directives are profile-specific directives.
	Directives *Directives `toml:"env._"`

	// Required is the list of variable names that MUST be defined when
	// this profile is active.
	Required []string `toml:"required"`
}

// Directives hold built-in envee directives that affect how env is resolved.
// They are populated from [env._] in TOML.
type Directives struct {
	// File adds variables from a file (dotenv, json, yaml, toml formats).
	File []FileRef `toml:"file"`

	// Path prepends entries to $PATH.
	Path []PathEntry `toml:"path"`

	// Script is a path to a WASM module that contributes to the env.
	// Each script can return JSON patches: {"set": {...}, "unset": [...]}.
	Script []ScriptRef `toml:"script"`

	// Secret references a secret from a plugin.
	// Keyed by variable name (e.g., "DATABASE_PASSWORD").
	Secret map[string]SecretRef `toml:"secret"`

	// Source sources a bash script (executed in a sandboxed shell) and
	// imports the exported variables. Off by default; requires trust.
	Source []SourceRef `toml:"source"`
}

// FileRef is a single _.file directive.
type FileRef struct {
	// Path is the file path, relative to config_root unless absolute.
	Path string `toml:"path"`

	// Format is one of: "dotenv" (default), "json", "yaml", "toml".
	Format string `toml:"format"`

	// Required, when true, makes the file's existence mandatory.
	Required bool `toml:"required"`

	// Redact, when true, marks all values loaded from this file as
	// redactable in status/diff output.
	Redact bool `toml:"redact"`

	// Expand, when true, allows $VAR references inside the loaded values.
	Expand bool `toml:"expand"`
}

// PathEntry is a single _.path directive.
type PathEntry struct {
	// Path is the directory to add to $PATH.
	Path string `toml:"path"`

	// Position is "prepend" (default) or "append".
	Position string `toml:"position"`
}

// ScriptRef is a single _.script directive.
type ScriptRef struct {
	// Path to the .wasm file.
	Path string `toml:"path"`

	// Input is the JSON to pass to the script on startup.
	Input any `toml:"input"`

	// AllowEnv is the list of env var names the script can read.
	AllowEnv []string `toml:"allow_env"`

	// AllowRead is the list of file paths the script can read.
	AllowRead []string `toml:"allow_read"`

	// QuotaCPU is the maximum CPU time (e.g., "200ms").
	QuotaCPU string `toml:"quota_cpu"`

	// QuotaMemory is the maximum memory (e.g., "64MiB").
	QuotaMemory string `toml:"quota_memory"`
}

// SecretRef is a single _.secret.<NAME> directive.
type SecretRef struct {
	// Source is the plugin name (e.g., "op", "aws", "vault").
	Source string `toml:"source"`

	// Ref is the source-specific reference (e.g., "op://Dev/Database/password").
	Ref string `toml:"ref"`

	// Account is the optional account/identity to use.
	Account string `toml:"account"`

	// Vault is the optional vault (1Password).
	Vault string `toml:"vault"`

	// Profile is the optional profile (AWS, gcloud, etc.).
	Profile string `toml:"profile"`

	// Redact, when true, marks the value as redactable in output.
	Redact bool `toml:"redact"`

	// Required, when true, makes the secret's availability mandatory.
	Required bool `toml:"required"`
}

// SourceRef is a single _.source directive.
type SourceRef struct {
	Path   string `toml:"path"`
	Shell  string `toml:"shell"`  // "bash" (default), "sh"
	Redact bool   `toml:"redact"`
}

// SortedKeys returns the env variable names in sorted order (deterministic output).
func (c *Config) SortedKeys() []string {
	keys := make([]string, 0, len(c.Env))
	for k := range c.Env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
