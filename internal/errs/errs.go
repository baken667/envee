// Package errs defines the envee error type and helpers.
//
// Every error emitted by envee should be an *Error from this package so it
// carries a stable Code (E001, E002, ...) and a human-readable Hint and Doc.
//
// See docs/adr/0017-error-ux.md.
package errs

import (
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
)

// Severity classifies the error for user-facing display.
type Severity string

const (
	SeverityError Severity = "ERROR"
	SeverityWarn  Severity = "WARN"
	SeverityInfo  Severity = "INFO"
)

// Error is the canonical envee error type.
//
// Construct via New or Wrap. Print via Error() or Print.
type Error struct {
	Code     string            // E001, E002, ... stable across versions
	Severity Severity          // ERROR, WARN, INFO
	Summary  string            // short, one-line description
	Context  map[string]string // structured details (path, hash, key, ...)
	Hint     string            // what the user can do
	Doc      string            // URL with more info (https://envee.dev/errors/<code>)
	Cause    error             // optional wrapped error
}

// New builds an *Error with the given code and summary.
func New(code, summary string) *Error {
	return &Error{
		Code:     code,
		Severity: SeverityError,
		Summary:  summary,
		Doc:      defaultDoc(code),
	}
}

// Warn creates a warning-level error. Used for non-fatal issues.
func Warn(code, summary string) *Error {
	e := New(code, summary)
	e.Severity = SeverityWarn
	return e
}

// Wrap wraps an underlying error with en semantics.
func Wrap(cause error, code, summary string) *Error {
	return &Error{
		Code:     code,
		Severity: SeverityError,
		Summary:  summary,
		Cause:    cause,
		Doc:      defaultDoc(code),
	}
}

// WithContext attaches a key/value pair to the error context.
//
// Returns the receiver for chaining.
func (e *Error) WithContext(key, value string) *Error {
	if e.Context == nil {
		e.Context = make(map[string]string)
	}
	e.Context[key] = value
	return e
}

// WithHint attaches an actionable hint to the error.
func (e *Error) WithHint(hint string) *Error {
	e.Hint = hint
	return e
}

// WithCause attaches an underlying error.
func (e *Error) WithCause(cause error) *Error {
	e.Cause = cause
	return e
}

// Error implements the error interface.
func (e *Error) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "[envee] %s [%s]: %s", e.Severity, e.Code, e.Summary)

	if len(e.Context) > 0 {
		keys := make([]string, 0, len(e.Context))
		for k := range e.Context {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		b.WriteString("\n[envee]   context:")
		for _, k := range keys {
			fmt.Fprintf(&b, "\n[envee]     %s: %s", k, e.Context[k])
		}
	}
	if e.Hint != "" {
		fmt.Fprintf(&b, "\n[envee] HINT: %s", e.Hint)
	}
	if e.Doc != "" {
		fmt.Fprintf(&b, "\n[envee] DOC:  %s", e.Doc)
	}
	if e.Cause != nil {
		fmt.Fprintf(&b, "\n[envee] CAUSE: %v", e.Cause)
	}
	return b.String()
}

// Unwrap implements errors.Unwrap for compatibility with errors.Is/As.
func (e *Error) Unwrap() error {
	return e.Cause
}

// Print writes the error to the given writer.
func (e *Error) Print(w io.Writer) {
	fmt.Fprintln(w, e.Error())
}

// defaultDoc returns the documentation URL for a given error code.
func defaultDoc(code string) string {
	if code == "" {
		return ""
	}
	return "https://envee.dev/errors/" + strings.ToLower(code)
}

// Is implements errors.Is for *Error (matches on Code).
func (e *Error) Is(target error) bool {
	var t *Error
	if !errors.As(target, &t) {
		return false
	}
	return e.Code == t.Code
}

// ---- Helpers for common error categories -----------------------------------

// Trust returns an E001 error (trust required).
func Trust(path, hash string) *Error {
	return New("E001", "envee.toml is not trusted").
		WithContext("path", path).
		WithContext("hash", hash).
		WithHint("Run `envee trust` to review and approve its content.")
}

// ConfigParse returns an E002 error (TOML parse failure).
func ConfigParse(path string, line, col int, detail string) *Error {
	return New("E002", "failed to parse envee.toml").
		WithContext("path", path).
		WithContext("line", fmt.Sprintf("%d", line)).
		WithContext("column", fmt.Sprintf("%d", col)).
		WithContext("detail", detail).
		WithHint("Check TOML syntax at the indicated line.")
}

// ConfigValidation returns an E003 error.
func ConfigValidation(path, key, detail string) *Error {
	return New("E003", "invalid value in envee.toml").
		WithContext("path", path).
		WithContext("key", key).
		WithContext("detail", detail)
}

// RequiredVar returns an E008 error.
func RequiredVar(name, profile string) *Error {
	e := New("E008", "required variable not defined").
		WithContext("variable", name)
	if profile != "" {
		e = e.WithContext("profile", profile)
	}
	return e.WithHint("Set it in envee.toml, .env file, or via a secret plugin.")
}

// PluginNotFound returns an E009 error.
func PluginNotFound(source string) *Error {
	return New("E009", "secret plugin not found").
		WithContext("source", source).
		WithContext("plugin", "envee-plugin-"+source).
		WithHint(fmt.Sprintf("Install with: brew install baken/tap/envee-plugin-%s", source))
}

// CycleDetected returns an E007 error.
func CycleDetected(chain []string) *Error {
	return New("E007", "circular dependency in template").
		WithContext("chain", strings.Join(chain, " -> ")).
		WithHint("Break the cycle by using a constant value.")
}
