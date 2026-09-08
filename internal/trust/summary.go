// trust/summary.go — human-readable summary for the `envee trust` prompt.
package trust

import (
	"fmt"
	"strings"

	"github.com/baken667/envee/internal/config"
)

// Summary is a human-readable description of what trusting a config file enables.
//
// Field order is dictated by govet's fieldalignment check: slices first
// (24 B), then strings (16 B), then int (8 B).
type Summary struct {
	EnvVars      []string
	RedactedVars []string
	PathAdds     []string
	Files        []string
	Secrets      []string
	Watches      []string
	Warnings     []string
	Errors       []string
	Path         string
	Hash         string
	Schema       string
	Profile      string
	Scripts      int
}

// BuildSummary generates a Summary from a config.
func BuildSummary(cfg *config.Config) *Summary {
	s := &Summary{
		Path:    cfg.Path,
		Hash:    cfg.FileHash,
		Schema:  cfg.Schema,
		Profile: cfg.Profile,
	}

	// Env vars.
	if cfg.Directives != nil {
		s.PathAdds = append(s.PathAdds, pathStrings(cfg.Directives.Path)...)
		s.Files = append(s.Files, fileStrings(cfg.Directives.File)...)
		s.Scripts = len(cfg.Directives.Script)
		for name, ref := range cfg.Directives.Secret {
			s.Secrets = append(s.Secrets, fmt.Sprintf("%s://%s (source=%s)", name, ref.Ref, ref.Source))
		}
	}

	for k, v := range cfg.Env {
		if k == "_" || isMetaKey(k) {
			continue
		}
		// Detect redaction hint.
		if m, ok := v.(map[string]any); ok {
			if r, _ := m["redact"].(bool); r {
				s.RedactedVars = append(s.RedactedVars, k)
				continue
			}
		}
		if nameLooksSensitive(k) {
			s.RedactedVars = append(s.RedactedVars, k)
		}
		s.EnvVars = append(s.EnvVars, k)
	}

	// Security checks.
	if s.Scripts > 0 {
		s.Warnings = append(s.Warnings, fmt.Sprintf("%d script(s) referenced — review WASM modules", s.Scripts))
	}
	for _, name := range s.EnvVars {
		if nameLooksSensitive(name) {
			s.Warnings = append(s.Warnings, fmt.Sprintf("%s looks like a secret but redact=false", name))
		}
	}
	for _, sec := range s.Secrets {
		if strings.Contains(sec, "unknown://") {
			s.Errors = append(s.Errors, fmt.Sprintf("secret source unknown: %s", sec))
		}
	}

	return s
}

// String renders the Summary for display.
func (s *Summary) String() string {
	var b strings.Builder

	fmt.Fprintf(&b, "Trust %s\n", s.Path)
	fmt.Fprintf(&b, "  Schema:     %s\n", s.Schema)
	if s.Profile != "" {
		fmt.Fprintf(&b, "  Profile:    %s\n", s.Profile)
	}
	fmt.Fprintf(&b, "  Hash:       %s\n", s.Hash)
	b.WriteString("\n")

	fmt.Fprintf(&b, "  Env vars:   %d", len(s.EnvVars))
	if len(s.RedactedVars) > 0 {
		fmt.Fprintf(&b, " (%d marked redact)", len(s.RedactedVars))
	}
	b.WriteString("\n")

	if len(s.PathAdds) > 0 {
		fmt.Fprintf(&b, "  PATH adds:  %d\n", len(s.PathAdds))
		for _, p := range s.PathAdds {
			fmt.Fprintf(&b, "              - %s\n", p)
		}
	}

	if len(s.Files) > 0 {
		fmt.Fprintf(&b, "  Files:      %d\n", len(s.Files))
		for _, f := range s.Files {
			fmt.Fprintf(&b, "              - %s\n", f)
		}
	}

	if s.Scripts > 0 {
		fmt.Fprintf(&b, "  Scripts:    %d (review WASM modules)\n", s.Scripts)
	}

	if len(s.Secrets) > 0 {
		fmt.Fprintf(&b, "  Secrets:    %d\n", len(s.Secrets))
		for _, sec := range s.Secrets {
			fmt.Fprintf(&b, "              - %s\n", sec)
		}
	}

	b.WriteString("\n")
	if len(s.Warnings) > 0 {
		b.WriteString("Security warnings:\n")
		for _, w := range s.Warnings {
			fmt.Fprintf(&b, "  ⚠ %s\n", w)
		}
		b.WriteString("\n")
	}
	if len(s.Errors) > 0 {
		b.WriteString("Security errors (will block trust unless --force):\n")
		for _, e := range s.Errors {
			fmt.Fprintf(&b, "  ✗ %s\n", e)
		}
		b.WriteString("\n")
	}

	return b.String()
}

func pathStrings(paths []config.PathEntry) []string {
	out := make([]string, len(paths))
	for i, p := range paths {
		out[i] = p.Path
	}
	return out
}

func fileStrings(files []config.FileRef) []string {
	out := make([]string, len(files))
	for i, f := range files {
		out[i] = f.Path
		if f.Format != "" {
			out[i] += " (" + f.Format + ")"
		}
	}
	return out
}

// nameLooksSensitive returns true if the variable name suggests it holds
// a secret (TOKEN, PASSWORD, etc.) and should be marked redact.
func nameLooksSensitive(name string) bool {
	upper := strings.ToUpper(name)
	for _, sub := range []string{"KEY", "SECRET", "TOKEN", "PASSWORD", "CREDENTIAL", "AUTH", "PRIVATE"} {
		if strings.Contains(upper, sub) {
			return true
		}
	}
	return false
}

// isMetaKey returns true if k is a reserved top-level key (not an env var).
// Kept in sync with directive.isMetaKey.
func isMetaKey(k string) bool {
	switch k {
	case "watch", "extends", "required", "schema", "profile",
		"stop_search_up", "profile_from_branch":
		return true
	}
	return false
}

// ShowDiff returns a unified diff between the file content and a reference
// (used for "what changed since I last trusted" review).
// For MVP, we just return the file content as-is.
func ShowDiff(content []byte) string {
	return string(content)
}
