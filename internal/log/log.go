// Package log is a thin wrapper around log/slog with envee-specific conventions.
//
// It exposes a structured logger that writes to stderr by default and can be
// configured via the --log-level/--log-format flags or the ENVEE_LOG/ENVEE_LOG_FORMAT
// environment variables.
//
// Sensitive values (anything containing KEY/SECRET/TOKEN/PASSWORD/CREDENTIAL/AUTH)
// are redacted automatically by the redacting handler.
package log

import (
	"context"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync/atomic"
)

// Options configures the package-level logger.
type Options struct {
	// Level is the minimum log level to emit: trace, debug, info, warn, error.
	Level string
	// Format is "text" or "json".
	Format string
	// Writer overrides the default os.Stderr destination. Useful for tests.
	Writer io.Writer
}

// LevelTrace is below Debug. We use a custom level because slog doesn't ship one.
const LevelTrace slog.Level = -8

// current is the active logger. Swapped atomically on Configure.
var current = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
	Level: slog.LevelWarn,
}))

// Configure rebuilds the package-level logger with the given options.
//
// Safe to call multiple times — each call replaces the active logger.
func Configure(opts Options) error {
	w := opts.Writer
	if w == nil {
		w = os.Stderr
	}

	level := parseLevel(opts.Level)
	handlerOpts := &slog.HandlerOptions{
		Level:     level,
		AddSource: level <= slog.LevelDebug,
	}

	var h slog.Handler
	switch strings.ToLower(opts.Format) {
	case "json":
		h = slog.NewJSONHandler(w, handlerOpts)
	default:
		h = slog.NewTextHandler(w, handlerOpts)
	}

	current = slog.New(&redactingHandler{Handler: h})
	slog.SetDefault(current)
	return nil
}

// parseLevel converts a string to a slog.Level.
func parseLevel(s string) slog.Level {
	switch strings.ToLower(s) {
	case "trace":
		return LevelTrace
	case "debug":
		return slog.LevelDebug
	case "info":
		return slog.LevelInfo
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelWarn
	}
}

// ---- Convenience functions -------------------------------------------------

// Trace logs at trace level.
func Trace(msg string, args ...any) { current.Log(context.Background(), LevelTrace, msg, args...) }

// Debug logs at debug level.
func Debug(msg string, args ...any) { current.Debug(msg, args...) }

// Info logs at info level.
func Info(msg string, args ...any) { current.Info(msg, args...) }

// Warn logs at warn level.
func Warn(msg string, args ...any) { current.Warn(msg, args...) }

// Error logs at error level.
func Error(msg string, args ...any) { current.Error(msg, args...) }

// With returns a logger with the given attributes attached.
func With(args ...any) *slog.Logger { return current.With(args...) }

// quiet suppresses all non-error output when set.
var quietFlag atomic.Bool

// SetQuiet toggles quiet mode.
func SetQuiet(q bool) { quietFlag.Store(q) }

// IsQuiet reports whether quiet mode is active.
func IsQuiet() bool { return quietFlag.Load() }
