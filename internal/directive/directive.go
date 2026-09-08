// Package directive applies envee.toml directives (_.file, _.path, _.secret,
// _.script, _.source) to produce the final resolved environment.
//
// This is the orchestration layer that runs after config parsing and before
// shell export generation. See docs/adr/0002-config-format-toml.md and
// docs/adr/0011-template-engine.md.
package directive

import (
	"context"
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/baken667/envee/internal/config"
	"github.com/baken667/envee/internal/env"
	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/template"
)

// Directives is an alias for the config type, used in this package to avoid
// importing the long config name everywhere.
type Directives = config.Directives

// SecretRef is an alias for the config type.
type SecretRef = config.SecretRef

// Result is the output of Apply.
type Result struct {
	// Env is the resolved environment (vars + their values + metadata).
	Env *env.Map

	// PathPrepend contains directories to prepend to $PATH (in order).
	PathPrepend []string

	// RedactedKeys lists variables whose values should be masked in output.
	RedactedKeys []string
}

// ApplyOptions configures how Apply runs.
type ApplyOptions struct {
	// ConfigRoot is the absolute path to the envee.toml directory.
	ConfigRoot string

	// Profile is the active profile (empty = no profile).
	Profile string

	// Cwd is the current working directory (for template {{cwd}}).
	Cwd string

	// OSEnv is the OS environment (for template {{env.X}}).
	OSEnv map[string]string
}

// PluginResolver is the interface for secret/script plugins. The real
// implementation lives in internal/plugin; this interface allows tests to
// inject a mock without depending on the plugin runtime.
//
// For now (MVP), if a PluginResolver is nil, secret directives set
// "__UNRESOLVED__:source:ref" placeholders.
type PluginResolver interface {
	// ResolveSecret looks up a secret by source + ref.
	// The source identifies the plugin (e.g., "env", "op", "aws").
	// The ref is the source-specific reference (e.g., "DATABASE_PASSWORD").
	ResolveSecret(ctx context.Context, source, ref string) (string, error)
}

// Apply orchestrates directive resolution. Order matters:
//
//  1. _.file (lowest priority)
//  2. profile env (only if profile matches)
//  3. TOML [env] (highest priority — overrides everything)
//
// Then templates ({{config_root}}, {{profile}}, {{env.X}}) are evaluated
// in topological order, with PATH being added as the last layer.
func Apply(ctx context.Context, cfg *config.Config, opts ApplyOptions, reg PluginResolver) (*Result, error) {
	if cfg == nil {
		return nil, errs.New("E003", "no config provided")
	}
	if opts.OSEnv == nil {
		opts.OSEnv = make(map[string]string)
	}
	if opts.Cwd == "" {
		opts.Cwd = opts.ConfigRoot
	}

	res := &Result{Env: env.New()}

	// 1. Apply _.file directives (in TOML order; later overrides earlier).
	for i, ref := range cfg.Directives.File {
		if err := applyFileDirective(ctx, cfg, opts, res, ref, i); err != nil {
			return nil, err
		}
	}

	// 2. Apply profile env (if profile specified).
	if opts.Profile != "" {
		if prof, ok := cfg.Profiles[opts.Profile]; ok && prof != nil {
			// Validate required.
			if err := validateRequired(prof, res.Env); err != nil {
				return nil, err
			}
			for k, v := range prof.Env {
				val, redact, err := coerceValue(v)
				if err != nil {
					return nil, err
				}
				res.Env.SetWithMeta(env.Entry{
					Key:      k,
					Value:    val,
					Redacted: redact,
					Source:   "profile:" + opts.Profile,
				})
			}
		}
	}

	// 3. Apply TOML [env] (highest priority).
	for k, v := range cfg.Env {
		// Skip the special "_" key (used for directives) and reserved meta keys.
		if k == "_" || isMetaKey(k) {
			continue
		}
		// Detect secret shorthand: inline table with `source` + `ref`.
		if m, ok := v.(map[string]any); ok {
			if src, _ := m["source"].(string); src != "" {
				ref, _ := m["ref"].(string)
				if ref == "" {
					return nil, errs.New("E003", "secret shorthand missing 'ref'").
						WithContext("key", k)
				}
				if cfg.Directives == nil {
					cfg.Directives = &Directives{}
				}
				if cfg.Directives.Secret == nil {
					cfg.Directives.Secret = make(map[string]SecretRef)
				}
				redact, _ := m["redact"].(bool)
				required, _ := m["required"].(bool)
				cfg.Directives.Secret[k] = SecretRef{
					Source:   src,
					Ref:      ref,
					Redact:   redact,
					Required: required,
				}
				continue // resolve in step 6
			}
		}
		val, redact, err := coerceValue(v)
		if err != nil {
			return nil, err
		}
		res.Env.SetWithMeta(env.Entry{
			Key:      k,
			Value:    val,
			Redacted: redact,
			Source:   "toml",
		})
	}

	// 4. Apply _.path directives. Store as raw strings; templates expanded later.
	for _, ref := range cfg.Directives.Path {
		path := ref.Path
		// If path is relative and doesn't contain a template, join with config_root.
		// If it contains a template (e.g., {{config_root}}/bin), let the template
		// engine produce the absolute path.
		if !filepath.IsAbs(path) && !strings.Contains(path, "{{") {
			path = filepath.Join(opts.ConfigRoot, path)
		}
		res.PathPrepend = append(res.PathPrepend, path)
	}

	// 5. Template evaluation in topological order.
	if err := evaluateTemplates(res, opts); err != nil {
		return nil, err
	}

	// 5b. Template evaluation for PATH entries.
	if err := expandPathTemplates(res, opts); err != nil {
		return nil, err
	}

	// 6. Resolve secret directives (_.secret.*).
	if err := applySecretDirectives(ctx, cfg, opts, res, reg); err != nil {
		return nil, err
	}

	// 7. Reject attempts to set envee's own control variables.
	if err := rejectReservedKeys(res); err != nil {
		return nil, err
	}

	return res, nil
}

// reservedKeyPrefix guards envee's own namespace.
//
// envee exports whatever a config produces straight into the user's shell.
// If a config could set ENVEE_* variables it would be configuring envee
// itself for every subsequent directory in that session — a config in one
// project could change how envee behaves in every other one. Checking here,
// after all directives have run, covers every source (TOML env, profiles,
// dotenv files loaded via _.file, and secret plugins) in one place.
const reservedKeyPrefix = "ENVEE_"

func rejectReservedKeys(res *Result) error {
	for _, k := range res.Env.Keys() {
		if strings.HasPrefix(k, reservedKeyPrefix) {
			return errs.New("E003", "config may not set reserved variable").
				WithContext("key", k).
				WithHint("Variables starting with " + reservedKeyPrefix +
					" configure envee itself and cannot be set from a config file.")
		}
	}
	return nil
}

// coerceValue converts a TOML-decoded value (which may be a string, int64,
// bool, or map[string]any for inline tables) to a string + redact flag.
func coerceValue(v any) (string, bool, error) {
	switch x := v.(type) {
	case string:
		return x, false, nil
	case int64:
		return fmt.Sprintf("%d", x), false, nil
	case bool:
		// false is reserved as "unset" sentinel — caller should handle.
		return fmt.Sprintf("%t", x), false, nil
	case float64:
		return fmt.Sprintf("%g", x), false, nil
	case map[string]any:
		// Inline table: { value = ..., redact = true, ... }
		val, _ := x["value"].(string)
		if b, ok := x["value"].(bool); ok {
			val = fmt.Sprintf("%t", b)
		}
		if i, ok := x["value"].(int64); ok {
			val = fmt.Sprintf("%d", i)
		}
		if f, ok := x["value"].(float64); ok {
			val = fmt.Sprintf("%g", f)
		}
		if arr, ok := x["value"].([]any); ok {
			val = formatAnyArray(arr)
		}
		redact, _ := x["redact"].(bool)
		return val, redact, nil
	case []any:
		return formatAnyArray(x), false, nil
	case nil:
		return "", false, nil
	}
	return fmt.Sprintf("%v", v), false, nil
}

// formatAnyArray formats a []any as a JSON-like array string.
func formatAnyArray(arr []any) string {
	parts := make([]string, len(arr))
	for i, item := range arr {
		parts[i] = fmt.Sprintf("%v", item)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// validateRequired checks that all required vars (from active profile) are set.
func validateRequired(prof *config.Profile, env *env.Map) error {
	for _, name := range prof.Required {
		if _, ok := env.Get(name); !ok {
			return errs.RequiredVar(name, "?").WithContext("profile_required", "true")
		}
	}
	return nil
}

// evaluateTemplates renders {{...}} expressions in all env values in
// topological order (deps first).
func evaluateTemplates(res *Result, opts ApplyOptions) error {
	eng := template.New()

	// Build env map for template context (initial state: pre-template values).
	tplEnv := make(map[string]string, res.Env.Len())
	for _, k := range res.Env.Keys() {
		v, _ := res.Env.Get(k)
		tplEnv[k] = v
	}

	// Build dependency graph (against current values).
	deps := make(map[string][]string)
	for _, k := range res.Env.Keys() {
		v, _ := res.Env.Get(k)
		deps[k] = template.ExtractVarRefs(v)
	}

	// Topo sort.
	order, err := topoSort(deps)
	if err != nil {
		return err
	}

	ctx := &template.Context{
		ConfigRoot: opts.ConfigRoot,
		Profile:    opts.Profile,
		Cwd:        opts.Cwd,
		Env:        tplEnv,
		OSEnv:      opts.OSEnv,
	}

	// Render in order.
	newMap := env.New()
	for _, k := range order {
		// Skip nodes that aren't in our resolved env (they were added
		// as deps but are external, like OS env vars).
		if _, exists := res.Env.GetWithMeta(k); !exists {
			continue
		}
		v, _ := res.Env.Get(k)
		meta, _ := res.Env.GetWithMeta(k)

		rendered, err := eng.Render(v, ctx)
		if err != nil {
			return err
		}
		// false in TOML = unset the variable.
		if rendered == "false" && meta.Source == "toml" {
			newMap.Unset(k)
			continue
		}
		meta.Value = rendered
		newMap.SetWithMeta(meta)
		// Update context for subsequent variables.
		tplEnv[k] = rendered
		ctx.Env = tplEnv
	}

	res.Env = newMap
	return nil
}

// topoSort computes a topologically sorted order of variables, ensuring
// that each variable is processed after the ones it depends on.
//
// Returns an error (E007) if a cycle is detected.
func topoSort(deps map[string][]string) ([]string, error) {
	visited := make(map[string]bool)
	inStack := make(map[string]bool)
	var order []string

	var visit func(string) error
	visit = func(n string) error {
		if inStack[n] {
			// Build the cycle chain for error reporting.
			chain := []string{n}
			return errs.CycleDetected(chain)
		}
		if visited[n] {
			return nil
		}
		visited[n] = true
		inStack[n] = true
		for _, m := range deps[n] {
			if err := visit(m); err != nil {
				return err
			}
		}
		inStack[n] = false
		order = append(order, n)
		return nil
	}

	keys := make([]string, 0, len(deps))
	for k := range deps {
		keys = append(keys, k)
	}
	sort.Strings(keys) // deterministic order
	for _, k := range keys {
		if err := visit(k); err != nil {
			return nil, err
		}
	}
	return order, nil
}

// applyFileDirective loads a single _.file entry.
func applyFileDirective(ctx context.Context, cfg *config.Config, opts ApplyOptions, res *Result, ref config.FileRef, idx int) error {
	return ApplyFile(ctx, opts.ConfigRoot, ref, func(key, value string) {
		res.Env.SetWithMeta(env.Entry{
			Key:      key,
			Value:    value,
			Redacted: ref.Redact,
			Source:   fmt.Sprintf("file:%s", ref.Path),
		})
	})
}

// applySecretDirectives resolves _.secret.* entries via the PluginResolver.
func applySecretDirectives(ctx context.Context, cfg *config.Config, opts ApplyOptions, res *Result, reg PluginResolver) error {
	if cfg.Directives == nil || len(cfg.Directives.Secret) == 0 {
		return nil
	}
	if reg == nil {
		// No resolver → placeholders with redaction.
		for name, ref := range cfg.Directives.Secret {
			res.Env.SetWithMeta(env.Entry{
				Key:      name,
				Value:    fmt.Sprintf("__UNRESOLVED__:%s:%s", ref.Source, ref.Ref),
				Redacted: true,
				Source:   "secret:unresolved",
			})
		}
		return nil
	}
	for name, ref := range cfg.Directives.Secret {
		val, err := reg.ResolveSecret(ctx, ref.Source, ref.Ref)
		if err != nil {
			if ref.Required {
				return errs.Wrap(err, "E004", "secret plugin failed").
					WithContext("source", ref.Source).
					WithContext("ref", ref.Ref)
			}
			// Non-required: skip silently.
			continue
		}
		res.Env.SetWithMeta(env.Entry{
			Key:      name,
			Value:    val,
			Redacted: ref.Redact,
			Source:   fmt.Sprintf("secret:%s", ref.Source),
		})
	}
	return nil
}

// expandPathTemplates renders {{...}} expressions in path entries.
func expandPathTemplates(res *Result, opts ApplyOptions) error {
	eng := template.New()
	tplEnv := make(map[string]string, res.Env.Len())
	for _, k := range res.Env.Keys() {
		v, _ := res.Env.Get(k)
		tplEnv[k] = v
	}
	ctx := &template.Context{
		ConfigRoot: opts.ConfigRoot,
		Profile:    opts.Profile,
		Cwd:        opts.Cwd,
		Env:        tplEnv,
		OSEnv:      opts.OSEnv,
	}
	for i, p := range res.PathPrepend {
		rendered, err := eng.Render(p, ctx)
		if err != nil {
			return err
		}
		res.PathPrepend[i] = rendered
	}
	return nil
}

// MergeStringPath joins path entries using the OS separator.
func MergeStringPath(parts []string) string {
	return strings.Join(parts, string(filepath.ListSeparator))
}

// metaKeys are top-level keys in envee.toml that are NOT env variables.
// They are reserved for envee's own use.
var metaKeys = map[string]bool{
	"watch":               true,
	"extends":             true,
	"required":            true,
	"schema":              true,
	"profile":             true,
	"stop_search_up":      true,
	"profile_from_branch": true,
}

// isMetaKey returns true if k is a reserved top-level key (not an env var).
func isMetaKey(k string) bool {
	return metaKeys[k]
}
