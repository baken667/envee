package log

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
)

// newTestLogger returns a logger writing JSON into buf through the redacting
// handler, so tests assert on what actually reaches the output.
func newTestLogger(buf *bytes.Buffer) *slog.Logger {
	base := slog.NewJSONHandler(buf, &slog.HandlerOptions{Level: slog.LevelDebug})
	return slog.New(&redactingHandler{Handler: base})
}

func TestIsSensitive(t *testing.T) {
	sensitive := []string{
		"API_KEY", "api_key", "DATABASE_PASSWORD", "GITHUB_TOKEN",
		"aws_secret_access_key", "MY_CREDENTIAL", "AUTH_HEADER", "PRIVATE_KEY",
	}
	for _, k := range sensitive {
		if !isSensitive(k) {
			t.Errorf("isSensitive(%q) = false, want true", k)
		}
	}
	benign := []string{"SERVICE_NAME", "PORT", "LOG_LEVEL", "DATABASE_URL", "path"}
	for _, k := range benign {
		if isSensitive(k) {
			t.Errorf("isSensitive(%q) = true, want false", k)
		}
	}
}

func TestRedactsStringValues(t *testing.T) {
	var buf bytes.Buffer
	newTestLogger(&buf).Info("resolved", "API_KEY", "sk_live_supersecret", "SERVICE_NAME", "myapp")

	out := buf.String()
	if strings.Contains(out, "sk_live_supersecret") {
		t.Errorf("secret leaked into the log: %s", out)
	}
	if !strings.Contains(out, Redacted) {
		t.Errorf("no redaction placeholder: %s", out)
	}
	// Non-sensitive values must survive, and the key itself must stay visible
	// so the reader knows which variable the line is about.
	if !strings.Contains(out, "myapp") || !strings.Contains(out, "API_KEY") {
		t.Errorf("over-redacted: %s", out)
	}
}

// Redaction used to be limited to slog.KindString, so a secret logged as any
// other kind went out in full.
func TestRedactsNonStringValues(t *testing.T) {
	cases := map[string]any{
		"any":      slog.AnyValue(struct{ V string }{"sk_live_supersecret"}),
		"int":      slog.IntValue(1234567890),
		"bool":     slog.BoolValue(true),
		"stringer": slog.AnyValue(secretStringer{}),
	}
	for name, v := range cases {
		t.Run(name, func(t *testing.T) {
			var buf bytes.Buffer
			newTestLogger(&buf).LogAttrs(context.Background(), slog.LevelInfo, "m",
				slog.Attr{Key: "SECRET_VALUE", Value: v.(slog.Value)})

			out := buf.String()
			if strings.Contains(out, "sk_live_supersecret") || strings.Contains(out, "1234567890") {
				t.Errorf("secret leaked for a %s value: %s", name, out)
			}
			if !strings.Contains(out, Redacted) {
				t.Errorf("value not redacted: %s", out)
			}
		})
	}
}

type secretStringer struct{}

func (secretStringer) String() string { return "sk_live_supersecret" }

func TestRedactsThroughWithAttrs(t *testing.T) {
	var buf bytes.Buffer
	logger := newTestLogger(&buf).With("GITHUB_TOKEN", "ghp_supersecret")
	logger.Info("hello")

	if out := buf.String(); strings.Contains(out, "ghp_supersecret") {
		t.Errorf("secret leaked through With(): %s", out)
	}
}

func TestRedactsInsideGroups(t *testing.T) {
	var buf bytes.Buffer
	newTestLogger(&buf).LogAttrs(context.Background(), slog.LevelInfo, "m",
		slog.Group("env",
			slog.String("DB_PASSWORD", "hunter2"),
			slog.String("SERVICE_NAME", "myapp"),
		))

	out := buf.String()
	if strings.Contains(out, "hunter2") {
		t.Errorf("secret leaked from inside a group: %s", out)
	}
	if !strings.Contains(out, "myapp") {
		t.Errorf("benign value inside the group was dropped: %s", out)
	}
}
