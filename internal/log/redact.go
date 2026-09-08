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
		if isSensitive(a.Key) && a.Value.Kind() == slog.KindString {
			a.Value = slog.StringValue("***REDACTED***")
		}
		clone.AddAttrs(a)
		return true
	})
	return h.Handler.Handle(ctx, clone)
}

// WithAttrs implements slog.Handler.
func (h *redactingHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	redacted := make([]slog.Attr, len(attrs))
	for i, a := range attrs {
		if isSensitive(a.Key) && a.Value.Kind() == slog.KindString {
			redacted[i] = slog.String(a.Key, "***REDACTED***")
		} else {
			redacted[i] = a
		}
	}
	return &redactingHandler{Handler: h.Handler.WithAttrs(redacted)}
}

// WithGroup implements slog.Handler.
func (h *redactingHandler) WithGroup(name string) slog.Handler {
	return &redactingHandler{Handler: h.Handler.WithGroup(name)}
}
