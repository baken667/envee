package log

import (
	"context"
	"log/slog"
	"strings"
)

// redactingHandler wraps another slog.Handler and redacts values of attributes
// whose keys look sensitive (containing KEY/SECRET/TOKEN/PASSWORD/etc.).
//
// We only redact values, not the keys themselves, so the user can still see
// which variable triggered the log line.
type redactingHandler struct {
	slog.Handler
}

var sensitiveSubstrings = []string{
	"KEY", "SECRET", "TOKEN", "PASSWORD", "CREDENTIAL", "AUTH", "PRIVATE",
}

// isSensitive returns true if the attribute name likely refers to a secret.
func isSensitive(key string) bool {
	upper := strings.ToUpper(key)
	for _, sub := range sensitiveSubstrings {
		if strings.Contains(upper, sub) {
			return true
		}
	}
	return false
}

// Redacted is the placeholder substituted for a sensitive value.
const Redacted = "***REDACTED***"

// redactAttr replaces the value of a sensitive attribute, and recurses into
// groups so a secret nested under one is not missed.
//
// Redaction deliberately ignores the value's kind. It used to apply only to
// slog.KindString, so a secret logged with slog.Any, slog.Int or a
// fmt.Stringer reached the log in full.
func redactAttr(a slog.Attr) slog.Attr {
	if a.Value.Kind() == slog.KindGroup {
		group := a.Value.Group()
		out := make([]any, 0, len(group))
		for _, g := range group {
			out = append(out, redactAttr(g))
		}
		return slog.Group(a.Key, out...)
	}
	if isSensitive(a.Key) {
		return slog.String(a.Key, Redacted)
	}
	return a
}

// Handle implements slog.Handler.
func (h *redactingHandler) Handle(ctx context.Context, r slog.Record) error {
	// Clone the record with redacted attributes.
	clone := slog.Record{
		Time:    r.Time,
		Message: r.Message,
		Level:   r.Level,
		PC:      r.PC,
	}
	r.Attrs(func(a slog.Attr) bool {
		clone.AddAttrs(redactAttr(a))
		return true
	})
	return h.Handler.Handle(ctx, clone)
}

// WithAttrs implements slog.Handler.
func (h *redactingHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	redacted := make([]slog.Attr, len(attrs))
	for i, a := range attrs {
		redacted[i] = redactAttr(a)
	}
	return &redactingHandler{Handler: h.Handler.WithAttrs(redacted)}
}

// WithGroup implements slog.Handler.
func (h *redactingHandler) WithGroup(name string) slog.Handler {
	return &redactingHandler{Handler: h.Handler.WithGroup(name)}
}
