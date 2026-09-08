// Package template implements envee's minimal template engine.
//
// Syntax: {{ expr | filter | filter(args) }}
//
// Supported expressions:
//   - config_root, profile, cwd
//   - env.X (from OS or already-resolved env)
//
// Supported filters:
//   - upper, lower, trim
//   - default("...")
//   - abspath, realpath, dirname, basename
//   - quote (shell-safe single-quote)
//   - json, base64
//
// See docs/adr/0011-template-engine.md.
package template

import (
	"fmt"
	"path/filepath"
	"strings"
)

// Context is the evaluation environment for a template.
type Context struct {
	ConfigRoot string
	Profile    string
	Cwd        string
	Env        map[string]string // already-resolved env
	OSEnv      map[string]string // original OS env
}

// Engine is a stateless template evaluator.
type Engine struct{}

// New returns a new Engine.
func New() *Engine { return &Engine{} }

// Render evaluates a template string with the given context.
//
// Returns the substituted string or an error if the template is malformed.
func (e *Engine) Render(tpl string, ctx *Context) (string, error) {
	var out strings.Builder
	i := 0
	for i < len(tpl) {
		if i+1 < len(tpl) && tpl[i] == '{' && tpl[i+1] == '{' {
			// Find closing }}
			end := strings.Index(tpl[i+2:], "}}")
			if end < 0 {
				return "", fmt.Errorf("unterminated template at offset %d", i)
			}
			expr := strings.TrimSpace(tpl[i+2 : i+2+end])
			val, err := e.evalExpr(expr, ctx)
			if err != nil {
				return "", fmt.Errorf("template %q: %w", expr, err)
			}
			out.WriteString(val)
			i += 2 + end + 2
			continue
		}
		out.WriteByte(tpl[i])
		i++
	}
	return out.String(), nil
}

// evalExpr evaluates a single {{ ... }} expression with optional pipe filters.
func (e *Engine) evalExpr(expr string, ctx *Context) (string, error) {
	parts := strings.Split(expr, "|")
	head := strings.TrimSpace(parts[0])

	// Look up the base value. If the variable is undefined AND a `default`
	// filter is present in the pipe chain, we treat the value as empty
	// (so the default kicks in). Otherwise we error.
	var val string
	hasDefault := false
	for _, f := range parts[1:] {
		if strings.HasPrefix(strings.TrimSpace(f), "default(") {
			hasDefault = true
			break
		}
	}

	switch {
	case head == "config_root":
		val = ctx.ConfigRoot
	case head == "profile":
		val = ctx.Profile
	case head == "cwd":
		val = ctx.Cwd
	case strings.HasPrefix(head, "env."):
		key := head[4:]
		if v, ok := ctx.Env[key]; ok {
			val = v
		} else if v, ok := ctx.OSEnv[key]; ok {
			val = v
		} else if hasDefault {
			val = "" // undefined, but default filter will substitute
		} else {
			return "", fmt.Errorf("undefined env var: %s", key)
		}
	default:
		return "", fmt.Errorf("unknown variable: %s", head)
	}

	// Apply filters.
	for _, f := range parts[1:] {
		f = strings.TrimSpace(f)
		name, args, err := parseFilter(f)
		if err != nil {
			return "", err
		}
		v, err := applyFilter(name, args, val, ctx)
		if err != nil {
			return "", err
		}
		val = v
	}

	return val, nil
}

// parseFilter splits a filter invocation into name and arg list.
func parseFilter(s string) (name string, args []string, err error) {
	open := strings.IndexByte(s, '(')
	if open < 0 {
		return strings.TrimSpace(s), nil, nil
	}
	if !strings.HasSuffix(s, ")") {
		return "", nil, fmt.Errorf("filter %q: missing closing paren", s)
	}
	name = strings.TrimSpace(s[:open])
	argStr := s[open+1 : len(s)-1]
	if argStr == "" {
		return name, nil, nil
	}
	// Naive split on comma; we don't support nested parens or escaped commas yet.
	for _, a := range strings.Split(argStr, ",") {
		args = append(args, strings.TrimSpace(a))
	}
	return name, args, nil
}

// applyFilter applies a single filter to the input value.
func applyFilter(name string, args []string, input string, ctx *Context) (string, error) {
	switch name {
	case "upper":
		return strings.ToUpper(input), nil
	case "lower":
		return strings.ToLower(input), nil
	case "trim":
		return strings.TrimSpace(input), nil
	case "default":
		if input != "" {
			return input, nil
		}
		if len(args) == 0 {
			return "", nil
		}
		// Unquote if necessary.
		return unquote(args[0]), nil
	case "abspath":
		return filepath.Abs(input)
	case "realpath":
		return filepath.EvalSymlinks(input)
	case "dirname":
		return filepath.Dir(input), nil
	case "basename":
		return filepath.Base(input), nil
	case "quote":
		return "'" + strings.ReplaceAll(input, "'", `'\''`) + "'", nil
	default:
		return "", fmt.Errorf("unknown filter: %s", name)
	}
}

// unquote removes surrounding quotes from a string literal.
func unquote(s string) string {
	if len(s) >= 2 {
		if (s[0] == '"' && s[len(s)-1] == '"') ||
			(s[0] == '\'' && s[len(s)-1] == '\'') {
			return s[1 : len(s)-1]
		}
	}
	return s
}
