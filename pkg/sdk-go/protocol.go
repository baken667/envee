package sdkgo

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"
)

// Metadata describes the plugin to envee core. Returned by the
// "metadata" subcommand.
type Metadata struct {
	Name         string   `json:"name"`
	Version      string   `json:"version"`
	APIVersion   int      `json:"api_version"`
	Description  string   `json:"description"`
	Capabilities []string `json:"capabilities"` // "secret", "source", "script", etc.
	Permissions  struct {
		Network    bool     `json:"network"`
		Filesystem []string `json:"filesystem"` // paths the plugin needs to read
		Exec       []string `json:"exec"`       // binaries the plugin needs to run
	} `json:"permissions"`
}

// Request is the JSON body sent to a plugin's "resolve" subcommand.
type Request struct {
	APIVersion int            `json:"api_version"`
	RequestID  string         `json:"request_id"`
	Spec       map[string]any `json:"spec"`
	Context    ReqContext     `json:"context"`
}

// ReqContext is the context block of a Request.
type ReqContext struct {
	ConfigRoot string            `json:"config_root"`
	Cwd        string            `json:"cwd"`
	Profile    string            `json:"profile"`
	Env        map[string]string `json:"env"`
}

// Response is the JSON body returned by a plugin's "resolve" subcommand.
type Response struct {
	APIVersion int           `json:"api_version"`
	RequestID  string        `json:"request_id"`
	Status     string        `json:"status"` // "ok" | "error"
	Value      *Value        `json:"value,omitempty"`
	Metadata   *RespMetadata `json:"metadata,omitempty"`
	Error      *PluginError  `json:"error,omitempty"`
}

// Value is the resolved value from a plugin.
type Value struct {
	Type  string `json:"type"`  // "string" | "int" | "bool" | "json"
	Value any    `json:"value"`
}

// RespMetadata describes the resolved value.
type RespMetadata struct {
	ResolvedAt time.Time `json:"resolved_at"`
	TTLSeconds int       `json:"ttl_seconds"`
	Source     string    `json:"source"`
}

// PluginError represents an error response from a plugin. It implements
// the error interface so it can be returned from Resolve.
type PluginError struct {
	Code        string `json:"code"`
	Message     string `json:"message"`
	Recoverable bool   `json:"recoverable"`
}

// Error implements the error interface.
func (e *PluginError) Error() string { return e.Message }

// Plugin is the user-provided plugin implementation.
type Plugin struct {
	Metadata Metadata
	// Resolve is called for each "resolve" subcommand invocation.
	// Returning an error with a *PluginError allows the plugin to
	// specify a structured error code.
	Resolve func(ctx context.Context, req Request) (Response, error)
}

// Run is the main entry point. It blocks until the process receives
// a shutdown signal.
func Run(p Plugin) {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: envee-plugin-<name> <metadata|resolve>")
		os.Exit(2)
	}

	subcommand := os.Args[1]
	switch subcommand {
	case "metadata":
		out, _ := json.Marshal(p.Metadata)
		fmt.Println(string(out))
	case "resolve":
		handleResolve(p)
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", subcommand)
		os.Exit(2)
	}
}

func handleResolve(p Plugin) {
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		writeError("", "internal", "read stdin: "+err.Error(), false)
		os.Exit(1)
	}

	var req Request
	if err := json.Unmarshal(data, &req); err != nil {
		writeError("", "invalid_request", "parse: "+err.Error(), false)
		os.Exit(1)
	}
	if req.APIVersion != APIVersion {
		writeError(req.RequestID, "version_mismatch",
			fmt.Sprintf("plugin API version %d, expected %d", req.APIVersion, APIVersion), false)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	resp, err := p.Resolve(ctx, req)
	if err != nil {
		// If err is a *PluginError, use it; otherwise wrap as internal.
		if pe, ok := err.(*PluginError); ok {
			writeErrorFull(req.RequestID, pe)
		} else {
			writeError(req.RequestID, "internal", err.Error(), true)
		}
		os.Exit(1)
	}
	resp.APIVersion = APIVersion
	resp.RequestID = req.RequestID
	if resp.Status == "" {
		resp.Status = "ok"
	}
	if resp.Metadata == nil {
		resp.Metadata = &RespMetadata{
			ResolvedAt: time.Now().UTC(),
			TTLSeconds: 900, // default 15 min
			Source:     p.Metadata.Name,
		}
	}

	out, _ := json.Marshal(resp)
	fmt.Println(string(out))
}

// OkResponse is a convenience constructor for a successful string response.
func OkResponse(value string) Response {
	return Response{
		Status: "ok",
		Value: &Value{
			Type:  "string",
			Value: value,
		},
	}
}

// OkResponseTTL is like OkResponse but with a custom TTL.
func OkResponseTTL(value string, ttl time.Duration) Response {
	return Response{
		Status: "ok",
		Value: &Value{
			Type:  "string",
			Value: value,
		},
		Metadata: &RespMetadata{
			ResolvedAt: time.Now().UTC(),
			TTLSeconds: int(ttl.Seconds()),
			Source:     "",
		},
	}
}

// writeError writes an error response to stdout (so envee can parse it).
func writeError(requestID, code, message string, recoverable bool) {
	writeErrorFull(requestID, &PluginError{
		Code:        code,
		Message:     message,
		Recoverable: recoverable,
	})
}

func writeErrorFull(requestID string, pe *PluginError) {
	resp := Response{
		APIVersion: APIVersion,
		RequestID:  requestID,
		Status:     "error",
		Error:      pe,
	}
	out, _ := json.Marshal(resp)
	fmt.Println(string(out))
}

// NewError is a convenience for plugins to construct *PluginError.
func NewError(code, message string, recoverable bool) *PluginError {
	return &PluginError{Code: code, Message: message, Recoverable: recoverable}
}
