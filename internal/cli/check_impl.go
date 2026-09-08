package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	"github.com/baken667/envee/internal/config"
	"github.com/baken667/envee/internal/errs"
	"github.com/baken667/envee/internal/resolver"
)

// Severity of a single check finding.
type findingLevel string

const (
	levelError   findingLevel = "error"
	levelWarning findingLevel = "warning"
)

// finding is one problem discovered by `envee check`.
type finding struct {
	Level   findingLevel `json:"level"`
	File    string       `json:"file"`
	Key     string       `json:"key,omitempty"`
	Message string       `json:"message"`
	Hint    string       `json:"hint,omitempty"`
}

// checkReport is the --json payload.
type checkReport struct {
	Files    []string  `json:"files"`
	Findings []finding `json:"findings"`
	Errors   int       `json:"errors"`
	Warnings int       `json:"warnings"`
	OK       bool      `json:"ok"`
}

// secretishKey matches variable names that almost certainly hold a credential.
var secretishKey = regexp.MustCompile(`(?i)(^|_)(KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIALS?|PRIVATE)(_|$)`)

// checkConfig statically analyses a parsed config.
//
// It never applies directives: no plugin is executed, no script is run and no
// file is sourced. `envee check` is what you run BEFORE trusting a config, so
// it must have no side effects.
// strict additionally reports things that are normal in day-to-day use --
// an absent optional _.file, a _.path entry that does not exist yet -- which
// would otherwise be pure noise (an optional file that is missing is exactly
// what required = false is for).
func checkConfig(cfg *config.Config, knownPlugins map[string]bool, strict bool) []finding {
	var out []finding
	add := func(level findingLevel, key, msg, hint string) {
		out = append(out, finding{Level: level, File: cfg.Path, Key: key, Message: msg, Hint: hint})
	}

	root := filepath.Dir(cfg.Path)

	if cfg.Schema != "" && cfg.Schema != config.SchemaVersion {
		add(levelError, "", fmt.Sprintf("unknown schema %q (this build understands %q)", cfg.Schema, config.SchemaVersion),
			"Upgrade envee, or pin schema = \""+config.SchemaVersion+"\".")
	}

	resolve := func(p string) string {
		if filepath.IsAbs(p) || strings.Contains(p, "{{") {
			return p
		}
		return filepath.Join(root, p)
	}
	exists := func(p string) bool {
		if strings.Contains(p, "{{") {
			return true // templated; can't resolve without applying
		}
		_, err := os.Stat(p)
		return err == nil
	}

	// _.file — a missing file is an error only when required.
	for _, ref := range cfg.Directives.File {
		p := resolve(ref.Path)
		if exists(p) {
			continue
		}
		if ref.Required {
			add(levelError, "", "_.file references a missing file: "+ref.Path,
				"Create "+p+" or drop required = true.")
		} else if strict {
			add(levelWarning, "", "optional _.file is absent: "+ref.Path,
				"It will be skipped at eval time. This is what required = false is for.")
		}
	}

	// _.script / _.source — always an error; these cannot be skipped.
	for _, ref := range cfg.Directives.Script {
		if p := resolve(ref.Path); !exists(p) {
			add(levelError, "", "_.script references a missing file: "+ref.Path, "")
		}
	}
	for _, ref := range cfg.Directives.Source {
		if p := resolve(ref.Path); !exists(p) {
			add(levelError, "", "_.source references a missing file: "+ref.Path, "")
		}
	}

	// _.path — directories like node_modules/.bin legitimately appear only
	// after a build, so this is a --strict-only observation.
	if strict {
		for _, ref := range cfg.Directives.Path {
			if p := resolve(ref.Path); !exists(p) {
				add(levelWarning, "", "_.path entry does not exist: "+ref.Path, "")
			}
		}
	}

	// Secrets — declared either as [env._.secret.NAME] or in the shorthand
	// form NAME = { source = "...", ref = "..." } under [env]. Apply() lifts
	// the shorthand at eval time, so check has to understand both.
	secrets := cfg.SecretRefs()
	secretKeys := make([]string, 0, len(secrets))
	for k := range secrets {
		secretKeys = append(secretKeys, k)
	}
	sort.Strings(secretKeys)
	for _, k := range secretKeys {
		ref := secrets[k]
		if ref.Source == "" {
			add(levelError, k, "secret is missing 'source'", "")
			continue
		}
		if ref.Ref == "" {
			add(levelError, k, "secret is missing 'ref'", "")
		}
		if knownPlugins != nil && !knownPlugins[ref.Source] {
			add(levelWarning, k, "no plugin found for secret source "+ref.Source,
				"Install envee-plugin-"+ref.Source+" and make sure it is on $PATH.")
		}
		if !ref.Redact {
			add(levelWarning, k, "secret is not marked redact = true",
				"Its value will be printed in full by `envee status` and `envee diff`.")
		}
	}

	// Reserved namespace and credential hygiene over the plain [env] table.
	envKeys := make([]string, 0, len(cfg.Env))
	for k := range cfg.Env {
		envKeys = append(envKeys, k)
	}
	sort.Strings(envKeys)
	for _, k := range envKeys {
		if k == "_" {
			continue
		}
		if strings.HasPrefix(k, "ENVEE_") {
			add(levelError, k, "config may not set reserved ENVEE_* variables",
				"These configure envee itself and are rejected at eval time.")
			continue
		}
		if _, isSecret := secrets[k]; isSecret {
			continue
		}
		if secretishKey.MatchString(k) && !isRedacted(cfg.Env[k]) {
			add(levelWarning, k, "looks like a credential but is a plaintext literal",
				"Use [env._.secret."+k+"] with a plugin, or set redact = true.")
		}
	}

	// Template cycles.
	if cycle := findTemplateCycle(cfg); cycle != "" {
		add(levelError, "", "circular template reference: "+cycle,
			"Break the cycle; templates are resolved in dependency order.")
	}

	return out
}

// isRedacted reports whether an [env] value is an inline table with
// redact = true (or is itself a secret reference).
func isRedacted(v any) bool {
	m, ok := v.(map[string]any)
	if !ok {
		return false
	}
	if r, ok := m["redact"].(bool); ok && r {
		return true
	}
	src, _ := m["source"].(string)
	return src != ""
}

var templateRef = regexp.MustCompile(`\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*(\||\}\})`)

// findTemplateCycle looks for env keys whose templates reference each other in
// a loop. Returns a human-readable cycle, or "" when the graph is acyclic.
func findTemplateCycle(cfg *config.Config) string {
	deps := make(map[string][]string)
	for k, v := range cfg.Env {
		s, ok := v.(string)
		if !ok {
			continue
		}
		for _, m := range templateRef.FindAllStringSubmatch(s, -1) {
			if _, isVar := cfg.Env[m[1]]; isVar {
				deps[k] = append(deps[k], m[1])
			}
		}
	}

	const (
		white = 0
		grey  = 1
		black = 2
	)
	state := make(map[string]int, len(deps))
	var stack []string
	var walk func(string) string
	walk = func(n string) string {
		state[n] = grey
		stack = append(stack, n)
		for _, d := range deps[n] {
			switch state[d] {
			case grey:
				return strings.Join(append(stack, d), " -> ")
			case white:
				if c := walk(d); c != "" {
					return c
				}
			}
		}
		stack = stack[:len(stack)-1]
		state[n] = black
		return ""
	}

	keys := make([]string, 0, len(deps))
	for k := range deps {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if state[k] == white {
			stack = stack[:0]
			if c := walk(k); c != "" {
				return c
			}
		}
	}
	return ""
}

// pluginsOnPath reports, for each secret source referenced by cfg, whether an
// envee-plugin-<source> executable is on $PATH.
//
// It deliberately uses LookPath rather than the plugin registry's Discover,
// which executes every plugin to fetch its metadata. `envee check` is meant to
// be safe to run against a config you have not yet trusted, so it must not
// spawn anything.
func pluginsOnPath(cfg *config.Config) map[string]bool {
	secrets := cfg.SecretRefs()
	out := make(map[string]bool, len(secrets))
	for _, ref := range secrets {
		if ref.Source == "" || out[ref.Source] {
			continue
		}
		_, err := exec.LookPath("envee-plugin-" + ref.Source)
		out[ref.Source] = err == nil
	}
	return out
}

func printFindings(w *os.File, findings []finding) {
	for _, f := range findings {
		loc := f.File
		if f.Key != "" {
			loc += ": " + f.Key
		}
		fmt.Fprintf(w, "  %-7s %s\n           %s\n", strings.ToUpper(string(f.Level)), loc, f.Message)
		if f.Hint != "" {
			fmt.Fprintf(w, "           hint: %s\n", f.Hint)
		}
	}
}

func writeJSONReport(rep checkReport) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(rep)
}

// runCheck implements `envee check [path]`.
//
// With no argument it analyses every config file the resolver would load for
// the current directory. With a path it analyses that single file. It does not
// require the config to be trusted -- checking is what you do before trusting.
func runCheck(cmd *cobra.Command, args []string, strict, jsonOut bool) error {
	var configs []*config.Config

	switch {
	case len(args) == 1:
		cfg, err := config.Parse(args[0])
		if err != nil {
			return err
		}
		configs = append(configs, cfg)

	default:
		if p, _ := cmd.Flags().GetString("config"); p != "" {
			cfg, err := config.Parse(p)
			if err != nil {
				return err
			}
			configs = append(configs, cfg)
			break
		}
		cwd, err := os.Getwd()
		if err != nil {
			return err
		}
		res, err := resolver.New(cwd)
		if err != nil {
			return err
		}
		profile, _ := cmd.Flags().GetString("profile")
		if profile == "" {
			profile = os.Getenv("ENVEE_PROFILE")
		}
		res.SetProfile(profile)

		files, err := res.Discover()
		if err != nil {
			return err
		}
		if len(files) == 0 {
			return errs.New("E003", "no envee.toml found").
				WithContext("dir", cwd).
				WithHint("Create an envee.toml, or pass a path: envee check path/to/envee.toml")
		}
		for _, f := range files {
			cfg, err := config.Parse(f)
			if err != nil {
				return err
			}
			configs = append(configs, cfg)
		}
	}

	rep := checkReport{Findings: []finding{}}
	for _, cfg := range configs {
		rep.Files = append(rep.Files, cfg.Path)
		rep.Findings = append(rep.Findings, checkConfig(cfg, pluginsOnPath(cfg), strict)...)
	}
	for _, f := range rep.Findings {
		if f.Level == levelError {
			rep.Errors++
		} else {
			rep.Warnings++
		}
	}
	rep.OK = rep.Errors == 0 && (!strict || rep.Warnings == 0)

	if jsonOut {
		if err := writeJSONReport(rep); err != nil {
			return err
		}
	} else {
		for _, f := range rep.Files {
			fmt.Printf("checking %s\n", f)
		}
		if len(rep.Findings) == 0 {
			fmt.Println("no problems found")
		} else {
			printFindings(os.Stdout, rep.Findings)
			fmt.Printf("\n%d error(s), %d warning(s)\n", rep.Errors, rep.Warnings)
		}
	}

	if !rep.OK {
		return errs.New("E003", "config check failed").
			WithContext("errors", fmt.Sprintf("%d", rep.Errors)).
			WithContext("warnings", fmt.Sprintf("%d", rep.Warnings))
	}
	return nil
}
